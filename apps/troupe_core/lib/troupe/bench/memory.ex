defmodule Troupe.Bench.Memory do
  @moduledoc """
  The offline bench's memory scenario (#248, Decision 838): a repository whose memory
  holds a command anchored on `mix.exs`, written and checked by a librarian, after which
  the alias it names changed.

  The first prompt has to carry the command marked "may no longer be true", and name
  `recall` for the facts it does not carry; the scripted model asks `recall` about the gate
  only when it finds the mark, and `recall` has to answer with the same status. What the
  brief took of the first prompt is held to a budget in `priv/bench/budgets.json`, as the
  instructions' is.
  """

  alias Troupe.Bench.{Model, Scenario}
  alias Troupe.Memory.Facts
  alias Troupe.Session.Memory, as: Brief

  @mix """
  defmodule Harbour.MixProject do
    use Mix.Project

    def project, do: [app: :harbour, version: "0.1.0", aliases: aliases()]

    defp aliases, do: [check: ["compile --warnings-as-errors", "credo --strict", "test"]]
  end
  """

  @gate "`mix check` is the gate: compile, credo, tests."
  @mark "- #{@gate} (may no longer be true: `mix.exs` changed since it was checked)"
  @recalled "[command, may no longer be true: a file it rests on changed since] #{@gate}"

  @doc "The memory scenarios, in report order."
  @spec all() :: [Scenario.t()]
  def all, do: [stale_anchor()]

  defp stale_anchor do
    %Scenario{
      name: "memory_stale_anchor",
      title: "a command whose file changed is marked in the prompt, and recall says so",
      prompt: "Run the project's gate and say whether it passes.",
      files: %{"mix.exs" => @mix},
      config: [memory: true],
      prepare: &remember/1,
      script: [&ask_if_marked/1, &answer/1],
      measure: &measure/1
    }
  end

  @doc """
  What a librarian leaves (a command anchored on `mix.exs`, an overview and a layout fact,
  and its stamp), then a change to the alias the command rests on.
  """
  @spec remember(map()) :: map()
  def remember(%{workspace: workspace}) do
    librarian = %{by: "librarian"}

    {:ok, _} =
      Facts.put(workspace, %{kind: "command", claim: @gate, anchors: ["mix.exs"]}, librarian)

    {:ok, _} =
      Facts.put(
        workspace,
        %{kind: "overview", claim: "A harbour's notes, as a Mix project."},
        librarian
      )

    {:ok, _} = Facts.put(workspace, %{kind: "layout", claim: "`lib/` holds the code."}, librarian)
    :ok = Brief.checked(workspace)
    File.write!(Path.join(workspace, "mix.exs"), String.replace(@mix, ~s("credo --strict", ), ""))
    %{}
  end

  # The scripted model's one decision: a command marked as maybe untrue is asked about
  # before it is run; one that is not is run.
  defp ask_if_marked(request) do
    if Model.prompt_text(request) =~ @mark,
      do: {:tools, [{"recall", %{"query" => "gate"}}]},
      else: {:text, "Running mix check."}
  end

  defp answer(request) do
    if (Model.last_tool_result(request) || "") =~ @recalled,
      do: {:text, "The gate may have changed since it was written down: mix.exs first."},
      else: {:text, "The gate is mix check."}
  end

  defp measure(ctx) do
    [{first, _task, _usage} | rest] = ctx.requests
    system = first.system || ""

    recalled =
      Enum.any?(rest, fn {request, _task, _usage} ->
        (Model.last_tool_result(request) || "") =~ @recalled
      end)

    {[{"brief_bytes", "the brief in the first prompt", "bytes", brief_bytes(system)}],
     [
       {"marked", "the first prompt marks the command whose file changed", system =~ @mark},
       {"named", "the first prompt names recall for the other facts",
        system =~ "2 more facts about this repository (1 overview and 1 layout)"},
       {"recalled", "recall answers the command as may no longer be true", recalled}
     ]}
  end

  # From the brief's heading to the environment's section that follows it.
  defp brief_bytes(system) do
    case String.split(system, "# Project brief\n", parts: 2) do
      [_before, brief] ->
        [brief | _] = String.split(brief, "\n\n<environment>", parts: 2)
        byte_size("# Project brief\n" <> brief)

      [_none] ->
        0
    end
  end
end
