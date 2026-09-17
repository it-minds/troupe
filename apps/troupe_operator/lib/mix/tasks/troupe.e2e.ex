defmodule Mix.Tasks.Troupe.E2e do
  @moduledoc """
  The suite that runs against a real cluster.

      mix troupe.e2e
      mix troupe.e2e --context kind-troupe-dev
      mix troupe.e2e test/e2e/enrolment_test.exs

  Everything under `apps/troupe_operator/test/e2e` is tagged `:e2e` and excluded from
  `mix test`, because a suite that deletes pods must not run because somebody typed the
  usual thing. This is the only way to run it, and it makes one check before it does.

  ## The guard

  It refuses any kubeconfig context whose name is not `kind-troupe-dev` — the one
  `scripts/remote-up` creates — unless `TROUPE_E2E_CONTEXT` names another *and*
  `TROUPE_E2E_I_MEAN_IT=1` is set. An end-to-end suite that kills pods and removes
  namespaces is one `KUBECONFIG` away from doing it somewhere real, and the distance
  between "the wrong terminal" and "production" should not be a habit.

  The check is on the *current* context as `kubectl` reports it, not on what this task
  was told, because what `kubectl` reports is what the suite will act on.

  ## What it does not do

  It never creates the cluster. `scripts/remote-up` does that, and a suite that could
  would be a suite that quietly rebuilt what it was supposed to be testing.
  """

  use Mix.Task

  @shortdoc "Run the cluster suite against a kind cluster brought up by scripts/remote-up"

  @default_context "kind-troupe-dev"
  @preferred_cli_env :test

  @impl Mix.Task
  def run(args) do
    {opts, files} = OptionParser.parse!(args, strict: [context: :string, trace: :boolean])

    context = opts[:context] || System.get_env("TROUPE_E2E_CONTEXT") || @default_context

    with :ok <- kubectl_present(),
         {:ok, current} <- current_context(),
         :ok <- permitted(current, context) do
      System.put_env("TROUPE_E2E_CONTEXT", current)
      run_suite(files, opts)
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp run_suite(files, opts) do
    paths = if files == [], do: ["test/e2e"], else: files

    Mix.Task.run("do", [
      "--app",
      "troupe_operator",
      "test",
      "--only",
      "e2e",
      "--max-cases",
      "1",
      trace(opts) | paths
    ])
  end

  # One at a time. These share a cluster, and a cluster is not a sandbox: two tests
  # deleting pods at once would each be the other's fault injection.
  defp trace(opts), do: if(opts[:trace], do: "--trace", else: "--seed=0")

  defp kubectl_present do
    if System.find_executable("kubectl") do
      :ok
    else
      {:error, "mix troupe.e2e: kubectl is not on PATH. Bring a cluster up with scripts/remote-up."}
    end
  end

  defp current_context do
    case System.cmd("kubectl", ["config", "current-context"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, "mix troupe.e2e: no current kubeconfig context.\n#{output}"}
    end
  end

  defp permitted(current, expected) when current == expected, do: :ok

  defp permitted(current, expected) when expected == @default_context do
    {:error,
     """
     mix troupe.e2e: refusing to run.

     The current kubeconfig context is #{current}, and this suite deletes pods, removes
     namespaces and injects faults. It only runs against #{@default_context} — the cluster
     `scripts/remote-up` creates — unless you say otherwise deliberately:

         TROUPE_E2E_CONTEXT=#{current} TROUPE_E2E_I_MEAN_IT=1 mix troupe.e2e

     Switch context with: kubectl config use-context #{@default_context}
     """}
  end

  defp permitted(current, _expected) do
    if System.get_env("TROUPE_E2E_I_MEAN_IT") == "1" do
      Mix.shell().info("mix troupe.e2e: running against #{current}, as instructed.")
      :ok
    else
      {:error,
       "mix troupe.e2e: --context was given but TROUPE_E2E_I_MEAN_IT=1 was not. " <>
         "Naming a context is not the same as meaning it."}
    end
  end

  @doc false
  def preferred_cli_env, do: @preferred_cli_env
end
