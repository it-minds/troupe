defmodule Troupe.Tools.AskUser do
  @moduledoc """
  Ask the person a question and wait for the answer.

  A question may carry a list of options. A client then offers them as a numbered menu
  instead of an empty input box, and `multiple` decides whether the reader picks one or
  toggles several. Typing a free-text answer stays available either way, so an option
  list is a shortcut and never a cage.

  The waiting is `Troupe.Session.Questions`' (Decision 651): the tool task blocks there
  until `question.answer` arrives, and the answer text is the tool's result.
  """

  @behaviour Troupe.Tool

  alias Troupe.Session.Questions
  alias Troupe.Tool

  @max_options 9

  @impl Troupe.Tool
  def name, do: "ask_user"

  @impl Troupe.Tool
  def description do
    "Ask the user a question and wait for the answer. Use it only when you genuinely " <>
      "cannot proceed without a decision from the user. Pass `options` to offer concrete " <>
      "choices (at most #{@max_options}; the user picks by number and can still type " <>
      "something else), and `multiple: true` when several may be chosen at once."
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "question" => %{"type" => "string"},
        "options" => %{
          "type" => "array",
          "description" =>
            "Concrete answers to offer, at most #{@max_options}. Each is a plain string, or an object with `label` and an optional `description`.",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "label" => %{"type" => "string"},
              "description" => %{"type" => "string"}
            },
            "required" => ["label"]
          }
        },
        "multiple" => %{
          "type" => "boolean",
          "description" => "Whether more than one option may be selected. Defaults to false."
        }
      },
      "required" => ["question"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, _question} <- Tool.fetch_string(args, "question") do
      question = normalize(args)

      case Questions.ask(ctx.session_id, %{
             call_id: ctx.call_id,
             agent_path: ctx.agent_path,
             question: question.question,
             options: question.options,
             multiple: question.multiple
           }) do
        {:ok, ""} -> {:ok, "(the user answered with nothing)"}
        {:ok, text} -> {:ok, text}
        {:error, :unattended} -> {:error, "nobody is attached to this session to answer; decide yourself or finish"}
      end
    end
  end

  @doc "The largest number of options a question may offer, one per digit key."
  @spec max_options() :: pos_integer()
  def max_options, do: @max_options

  @doc """
  Normalises whatever the model sent.

  Models are loose with this shape: options arrive as bare strings, as objects under
  `label`/`name`/`value`/`text`, with blank or duplicate labels, or in their hundreds.
  Everything is coerced here, once, so the event, the client and the answer agree on
  what was offered.
  """
  @spec normalize(map()) :: %{question: String.t(), options: [map()], multiple: boolean()}
  def normalize(input) when is_map(input) do
    %{
      question: input |> Map.get("question", "") |> to_string() |> String.trim(),
      options: input |> Map.get("options") |> normalize_options(),
      multiple: Map.get(input, "multiple") in [true, "true"]
    }
  end

  def normalize(_input), do: %{question: "", options: [], multiple: false}

  defp normalize_options(list) when is_list(list) do
    list
    |> Enum.map(&normalize_option/1)
    |> Enum.reject(&(&1.label == ""))
    |> Enum.uniq_by(& &1.label)
    |> Enum.take(@max_options)
  end

  defp normalize_options(_other), do: []

  defp normalize_option(label) when is_binary(label), do: %{label: one_line(label), description: nil}

  defp normalize_option(option) when is_map(option) do
    label =
      Enum.find_value(["label", "name", "value", "text", "title"], "", fn key ->
        case Map.get(option, key) do
          value when is_binary(value) or is_number(value) -> to_string(value)
          _ -> nil
        end
      end)

    %{label: one_line(label), description: description(option)}
  end

  defp normalize_option(other) when is_number(other), do: %{label: to_string(other), description: nil}
  defp normalize_option(_other), do: %{label: "", description: nil}

  defp description(option) do
    case Map.get(option, "description") || Map.get(option, "detail") do
      value when is_binary(value) ->
        case one_line(value) do
          "" -> nil
          text -> text
        end

      _ ->
        nil
    end
  end

  defp one_line(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
end
