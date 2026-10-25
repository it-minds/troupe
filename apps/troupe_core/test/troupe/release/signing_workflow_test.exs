defmodule Troupe.Release.SigningWorkflowTest do
  @moduledoc """
  How the release's OS code signing is wired (docs/developer/code-signing.md): read from
  the workflow files, so a change that would let an unsigned build see a secret, sign after
  the files are uploaded, or have the manifest written before the native builds finish
  fails here rather than on the day the certificates exist. The signing itself is run by
  `signing.yml`, self-signed, on a Mac and on Windows.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../../..", __DIR__)

  defp workflow(name) do
    {:ok, yaml} = YamlElixir.read_from_file(Path.join(@root, ".github/workflows/#{name}"))
    yaml
  end

  defp step_index(steps, pred), do: Enum.find_index(steps, pred)
  defp named(prefix), do: &String.starts_with?(&1["name"] || "", prefix)
  defp uses(action), do: &String.starts_with?(&1["uses"] || "", action)

  test "only release.yml asks for signing; the nightly, a pre-release and a pull request build unsigned" do
    release = workflow("release.yml")
    assert release["jobs"]["native"]["with"]["sign"] == "release"
    # The manifest the release key signs is written after the native builds, which sign.
    assert "native" in release["jobs"]["publish"]["needs"]

    for {file, job} <- [
          {"nightly.yml", "native"},
          {"prerelease.yml", "native"},
          {"ci.yml", "native"}
        ] do
      refute Map.has_key?(workflow(file)["jobs"][job]["with"] || %{}, "sign"),
             "#{file}'s #{job} job asks native.yml to sign"
    end

    assert workflow("signing.yml")["jobs"]["native"]["with"]["sign"] == "self-signed"
  end

  test "the release environment, whose secrets these are, is named only for a signed release" do
    jobs = workflow("native.yml")["jobs"]

    for job <- ~w(signing daemon tui desktop) do
      env = jobs[job]["environment"]

      assert is_binary(env) and env =~ "inputs.sign == 'release'" and env =~ "'release'",
             "the #{job} job's environment is #{inspect(env)}"
    end

    for {name, job} <- jobs, job["environment"] && name not in ~w(signing daemon tui desktop) do
      flunk("#{name} names an environment")
    end
  end

  test "no step reads a signing secret unless the build is a release's" do
    jobs = workflow("native.yml")["jobs"]

    for {name, job} <- jobs,
        step <- job["steps"] || [],
        {var, value} <- step["env"] || %{},
        is_binary(value) and value =~ "secrets." do
      guard = "#{step["if"]} #{value}"

      assert guard =~ "== 'release'",
             "#{name}: #{step["name"] || step["uses"]} reads #{var} from a secret without asking for a release"
    end
  end

  test "each build signs and checks its files before they are uploaded, and records them" do
    jobs = workflow("native.yml")["jobs"]

    for job <- ~w(daemon tui) do
      steps = jobs[job]["steps"]
      upload = step_index(steps, &(uses("actions/upload-artifact").(&1) and &1["if"] == nil))
      assert upload, "#{job} uploads nothing"

      signed = step_index(steps, named("Build the release, signed"))

      checked =
        step_index(steps, &((&1["run"] || "") =~ "-Verify" or (&1["run"] || "") =~ "--verify"))

      recorded = step_index(steps, named("Record what was signed"))

      assert signed && signed < upload, "#{job} signs after it uploads"
      assert checked && checked < upload, "#{job} checks the signatures after it uploads"
      assert recorded && recorded < upload, "#{job} records after it uploads"
    end

    tui = jobs["tui"]["steps"]
    binary = step_index(tui, named("Sign the binary"))
    smoke = step_index(tui, named("Smoke test"))
    assert binary < smoke, "the TUI's smoke test runs before its binary is signed"

    desktop = jobs["desktop"]["steps"]
    keep = step_index(desktop, named("Keep the installers"))
    assert step_index(desktop, named("The app is signed (macOS)")) < keep
    assert step_index(desktop, named("The installers and the app are signed (Windows)")) < keep
  end

  # The full suite of a pull request into `main` runs native.yml twice in one workflow run,
  # unsigned (ci.yml's `native`) and self-signed (signing.yml), and an artifact name one
  # build uses must not be one the other uses, or the manifest check reads the wrong file.
  test "the self-signed build's artifacts have names of their own, and only they are checked" do
    prefix = "${{ inputs.artifact_prefix }}"
    native = workflow("native.yml")["jobs"]

    for {job, %{"steps" => steps}} <- native, step <- steps do
      cond do
        uses("actions/upload-artifact").(step) ->
          assert String.starts_with?(step["with"]["name"], prefix),
                 "#{job} uploads #{step["with"]["name"]} without the prefix"

        uses("actions/download-artifact").(step) ->
          assert String.starts_with?(step["with"]["pattern"], prefix),
                 "#{job} downloads #{step["with"]["pattern"]} without the prefix"

        true ->
          :ok
      end
    end

    signing = workflow("signing.yml")["jobs"]
    own = signing["native"]["with"]["artifact_prefix"]
    assert is_binary(own) and own != ""

    downloads =
      for step <- signing["manifest"]["steps"], uses("actions/download-artifact").(step),
          do: step["with"]["pattern"]

    assert downloads != []
    assert Enum.all?(downloads, &String.starts_with?(&1, own)), inspect(downloads)

    # A release builds once, under the names its `attach` job looks for.
    refute Map.has_key?(workflow("release.yml")["jobs"]["native"]["with"], "artifact_prefix")
    refute Map.has_key?(workflow("ci.yml")["jobs"]["native"]["with"] || %{}, "artifact_prefix")
  end

  test "the release's files are signed before they are packed" do
    daemon = File.read!(Path.join(@root, "apps/troupe_daemon/mix.exs"))
    [steps] = Regex.run(~r/steps: \[(.*?)\]/s, daemon, capture: :all_but_first)
    sign = :binary.match(steps, "&Troupe.Release.OSSigning.release/1")
    tar = :binary.match(steps, ":tar")
    assert sign != :nomatch and tar != :nomatch and elem(sign, 0) < elem(tar, 0)

    tui = File.read!(Path.join(@root, "clients/tui/mix.exs"))
    assert tui =~ "extra_steps: [patch: [post: [Troupe.Release.OSSigning]]]"
  end

  test "the desktop build's sign command is the signing script, found from where Tauri runs it" do
    conf =
      Path.join(@root, "clients/gui/apps/desktop/src-tauri/tauri.signing.conf.json")
      |> File.read!()
      |> Jason.decode!()

    %{"cmd" => "pwsh", "args" => args} = conf["bundle"]["windows"]["signCommand"]
    assert List.last(args) == "%1"

    # Tauri runs it in src-tauri and makes a relative argument that exists absolute.
    script = Enum.find(args, &String.ends_with?(&1, "sign-windows.ps1"))
    src_tauri = Path.join(@root, "clients/gui/apps/desktop/src-tauri")
    assert File.regular?(Path.expand(script, src_tauri))
  end
end
