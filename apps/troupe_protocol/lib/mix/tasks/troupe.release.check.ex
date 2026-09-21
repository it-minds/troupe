defmodule Mix.Tasks.Troupe.Release.Check do
  @shortdoc "Everything that has to be true before a tag"

  @moduledoc """
  The gate for a release, composed of the gates that already exist.

      mix troupe.release.check
      mix troupe.release.check --skip e2e
      mix troupe.release.check --only version,egress

  ## Why a task rather than a checklist

  A checklist is a list of things somebody did once. Every step below already exists and is
  already run by something — `mix check` by CI on every push, `troupe.e2e` by hand against
  kind, `kubeconform` by nobody in particular — and the failure a release has is not that
  one of them is missing but that on the day of the tag two of them were run and the third
  was remembered as having passed.

  ## A step that cannot run says so, and says why

  `troupe.e2e` needs a cluster; `kubeconform` needs the binary. On a machine without either
  this task does not quietly succeed and does not fail either — it reports the step as **not
  run**, with the reason and the command that would run it, and exits non-zero only if a
  step that *could* have run did not pass.

  That distinction is the whole design. A release check that failed on a laptop would be one
  people learned to pass with `--skip`; one that passed silently would be a checklist with a
  progress bar. So the summary at the end is the artifact: every step, and for each one
  either a pass, a failure, or the reason it could not be attempted here.

  ## What this repository cannot check

  The GUI's Playwright suite runs from `clients/gui`, with its own toolchain, against the
  same cluster, and no Mix task can claim it passed. It is listed in the summary as owed by
  the GUI so that the list of what a release needs is complete even where this task cannot
  supply it.
  """

  use Mix.Task

  @steps [
    {:version, "one version string, everywhere it is written"},
    {:egress, "the generated allowlist matches the code, and the chart allows it"},
    {:schema, "no breaking protocol schema change"},
    {:check, "compile, format, credo, boundaries, tests"},
    {:kubeconform, "the chart renders and validates"},
    {:e2e, "the end-to-end suite, twice"},
    {:gui, "the GUI's Playwright suite, against the same cluster"}
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv, strict: [skip: :string, only: :string])

    wanted = wanted(opts)
    results = Enum.map(@steps, fn {step, what} -> {step, what, attempt(step, wanted)} end)

    report(results)

    failed = for {step, _what, {:failed, _why}} <- results, do: step

    if failed != [] do
      Mix.raise("release check failed: #{Enum.map_join(failed, ", ", &to_string/1)}")
    end
  end

  defp wanted(opts) do
    only = opts |> Keyword.get(:only) |> split()
    skip = opts |> Keyword.get(:skip) |> split()

    fn step ->
      name = to_string(step)
      (only == [] or name in only) and name not in skip
    end
  end

  defp split(nil), do: []
  defp split(value), do: String.split(value, ",", trim: true)

  defp attempt(step, wanted) do
    if wanted.(step), do: run_step(step), else: {:not_run, "asked to skip it"}
  end

  # -- the steps --------------------------------------------------------------

  defp run_step(:version), do: mix("test", ["apps/troupe_protocol/test/troupe/version_test.exs"])

  defp run_step(:egress) do
    case mix("troupe.egress", ["--check"]) do
      :passed -> mix("test", ["apps/troupe_protocol/test/troupe/egress_test.exs"])
      other -> other
    end
  end

  defp run_step(:schema), do: mix("troupe.schema.diff", [])

  defp run_step(:check), do: mix("check", [])

  defp run_step(:kubeconform) do
    case System.find_executable("kubeconform") do
      nil ->
        {:not_run, "kubeconform is not on PATH — `brew install kubeconform`, or see its README"}

      _found ->
        kubeconform()
    end
  end

  defp run_step(:e2e) do
    cond do
      is_nil(System.find_executable("kubectl")) ->
        {:not_run, "kubectl is not on PATH"}

      context() == nil ->
        {:not_run, "no current kubeconfig context — `scripts/remote-up` brings one up"}

      context() != "kind-troupe-dev" and System.get_env("TROUPE_E2E_I_MEAN_IT") != "1" ->
        {:not_run,
         "the current context is #{context()}, and the suite refuses anything but " <>
           "kind-troupe-dev without TROUPE_E2E_I_MEAN_IT=1"}

      true ->
        # Twice, because the suite that passes once may be the suite that left something
        # behind: the second run is the one that meets the first run's leftovers.
        case mix("troupe.e2e", []) do
          :passed -> mix("troupe.e2e", [])
          other -> other
        end
    end
  end

  defp run_step(:gui) do
    {:not_run,
     "it lives in clients/gui — run `pnpm test:e2e` there against the same cluster"}
  end

  # -- running things ---------------------------------------------------------

  defp mix(task, args) do
    case cmd("mix", [task | args]) do
      {_output, 0} -> :passed
      {output, status} -> {:failed, "mix #{task} exited #{status}\n#{tail(output)}"}
    end
  end

  defp kubeconform do
    case cmd("helm", ["template", "charts/troupe"]) do
      {rendered, 0} -> validate(rendered)
      {output, status} -> {:failed, "helm template exited #{status}\n#{tail(output)}"}
    end
  end

  defp validate(rendered) do
    path = Path.join(System.tmp_dir!(), "troupe-chart-#{System.unique_integer([:positive])}.yaml")
    File.write!(path, rendered)

    try do
      # `-strict` refuses unknown fields, which is the class of mistake a chart makes:
      # a key that reads correctly and that nothing consumes. `-ignore-missing-schemas`
      # for the CRDs this chart installs itself, which no public schema describes.
      case cmd("kubeconform", ["-strict", "-ignore-missing-schemas", "-summary", path]) do
        {_output, 0} -> :passed
        {output, status} -> {:failed, "kubeconform exited #{status}\n#{tail(output)}"}
      end
    after
      File.rm(path)
    end
  end

  defp cmd(executable, args) do
    System.cmd(executable, args, stderr_to_stdout: true, env: [{"MIX_ENV", nil}])
  rescue
    error -> {Exception.message(error), 1}
  end

  defp context do
    case cmd("kubectl", ["config", "current-context"]) do
      {output, 0} -> String.trim(output)
      _otherwise -> nil
    end
  end

  defp tail(output), do: output |> String.split("\n") |> Enum.take(-20) |> Enum.join("\n")

  # -- the summary, which is the artifact --------------------------------------

  defp report(results) do
    Mix.shell().info("\nrelease check\n")

    for {step, what, result} <- results do
      Mix.shell().info("  #{mark(result)} #{pad(step)} #{what}")

      case result do
        {:not_run, why} -> Mix.shell().info("      #{why}")
        {:failed, why} -> Mix.shell().error("      #{why}")
        :passed -> :ok
      end
    end

    counts = Enum.frequencies_by(results, fn {_step, _what, result} -> tag(result) end)

    Mix.shell().info(
      "\n  #{Map.get(counts, :passed, 0)} passed · " <>
        "#{Map.get(counts, :failed, 0)} failed · " <>
        "#{Map.get(counts, :not_run, 0)} not run here\n"
    )
  end

  defp tag(:passed), do: :passed
  defp tag({:failed, _why}), do: :failed
  defp tag({:not_run, _why}), do: :not_run

  defp mark(:passed), do: "ok  "
  defp mark({:failed, _why}), do: "FAIL"
  defp mark({:not_run, _why}), do: "--  "

  defp pad(step), do: step |> to_string() |> String.pad_trailing(13)
end
