defmodule Troupe.Tools.Finish do
  @moduledoc """
  How an agent reports to whoever delegated to it, in parts (#554, Decision 847).

  Deferred like `delegate`: the agent turns it into a `{:child_result, ref, result}`
  message to its parent and moves to `:done` once the turn's other calls are back. The
  parent sees this report and never the transcript, so the report has a shape it can be
  judged by without one: the `summary` the brief's deliverable asked for, what `ran`, what
  `passed`, what is `unverified`, and what the agent `needs` from its parent. A report
  missing one of those is refused, naming it, which is enough for a model to send it again
  whole.

  What `changed` is Troupe's to say where it can: the files the agent's file tools wrote,
  as a stat and where to read the diff (`Troupe.Agent.Writes`), filled in when the report
  is sent. The model's own `changed` is only for what those tools did not do.
  """

  @behaviour Troupe.Tool

  alias Troupe.Agent.Writes

  @parts ~w(summary ran passed unverified needs)

  @impl Troupe.Tool
  def name, do: "finish"

  @impl Troupe.Tool
  def mode, do: :inline

  @impl Troupe.Tool
  def description do
    "Report to whoever delegated to you; they see only this. Troupe adds what your file " <>
      "tools changed. Write none where a part has nothing."
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "summary" => %{"type" => "string", "description" => "The result asked for, in full."},
        "ran" => %{"type" => "string", "description" => "Commands run and what they showed."},
        "passed" => %{"type" => "string", "description" => "What you checked and saw pass."},
        "unverified" => %{
          "type" => "string",
          "description" => "What you did not check, or doubt."
        },
        "needs" => %{"type" => "string", "description" => "What you need from your parent."},
        "changed" => %{
          "type" => "string",
          "description" => "Changes your file tools did not make."
        }
      },
      "required" => @parts
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    with :ok <- none_running(ctx),
         {:ok, parts} <- parts(args),
         do: {:defer, {:finish, parts}}
  end

  # A finish is the whole report, and whoever delegated stops the agent once it has it:
  # a subagent of its own still at work in the background would be cut off with nothing
  # said of it (Decision 853).
  defp none_running(%{children: [_ | _] = running}) do
    {:error,
     "finish refused: #{and_list(running)} still #{if match?([_], running), do: "runs", else: "run"} " <>
       "in the background. End your turn to wait for its end, or stop it with stop_child, " <>
       "then finish."}
  end

  defp none_running(_ctx), do: :ok

  @doc "The parts of a `finish` call, or the sentence that refuses it."
  @spec parts(map()) :: {:ok, map()} | {:error, String.t()}
  def parts(args) do
    {found, missing} =
      Enum.reduce(@parts, {%{}, []}, fn part, {found, missing} ->
        case text(Map.get(args, part)) do
          nil -> {found, missing ++ [part]}
          value -> {Map.put(found, part, value), missing}
        end
      end)

    case missing do
      [] -> {:ok, put_text(found, "changed", Map.get(args, "changed"))}
      _ -> {:error, refusal(missing)}
    end
  end

  @doc """
  The parts a `finish` that came back before a restart gave, as a replay reads them off
  its call. One from before the parts existed gave a summary alone, and stays that.
  """
  @spec replayed(map()) :: map() | nil
  def replayed(args) do
    case parts(args) do
      {:ok, parts} -> parts
      {:error, _} -> if is_binary(args["summary"]), do: %{"summary" => args["summary"]}
    end
  end

  @doc """
  The parts of a subagent that answered in text and never called `finish`: its answer is
  the summary, and nothing it did not say is taken as checked.
  """
  @spec unreported(String.t()) :: map()
  def unreported(text) do
    %{
      "summary" => text,
      "ran" => "not said",
      "passed" => "not said",
      "unverified" => "all of it: it answered without calling finish",
      "needs" => "not said"
    }
  end

  @doc "Whether these are a summary alone, as a `finish` from before the parts gave."
  @spec legacy?(map()) :: boolean()
  def legacy?(parts), do: not Map.has_key?(parts, "ran")

  @doc """
  The report as its reader gets it: the summary, then each part under its name. A report
  from before the parts is its summary.
  """
  @spec render(map()) :: String.t()
  def render(%{"summary" => summary} = report) do
    if legacy?(report) do
      summary
    else
      # `changed` opens on its own line whatever follows it: what is under it is indented.
      parts =
        ["changed: " <> Writes.describe(report["changed"])] ++
          Enum.map(~w(ran passed unverified needs), &labelled({&1, report[&1]}))

      Enum.join([summary, Enum.join(parts, "\n")], "\n\n")
    end
  end

  @doc "A part under its name: on its line when it is one line, under it when it is more."
  @spec labelled({String.t(), String.t()}) :: String.t()
  def labelled({name, value}) do
    if String.contains?(value, "\n"), do: "#{name}:\n#{value}", else: "#{name}: #{value}"
  end

  @doc """
  A part's text: a string, or a list of strings as one line each. Blank is missing, as is
  anything else.
  """
  @spec text(term()) :: String.t() | nil
  def text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def text([_ | _] = items) do
    if Enum.all?(items, &is_binary/1),
      do: items |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> bullets()
  end

  def text(_value), do: nil

  defp bullets([]), do: nil
  defp bullets(lines), do: Enum.map_join(lines, "\n", &("- " <> &1))

  defp put_text(map, key, value) do
    case text(value) do
      nil -> map
      text -> Map.put(map, key, text)
    end
  end

  defp refusal(missing) do
    "finish refused: it has no #{and_list(missing)}. A finish has summary, ran, passed, " <>
      "unverified and needs, each its own field; write none where one has nothing, and " <>
      "call finish again with all five."
  end

  @doc false
  @spec and_list([String.t()]) :: String.t()
  def and_list([one]), do: one
  def and_list(items), do: Enum.join(Enum.drop(items, -1), ", ") <> " and " <> List.last(items)
end
