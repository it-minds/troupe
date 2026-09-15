defmodule Troupe.Tools.AskUser do
  @moduledoc """
  Schema and input normalisation; executed by `Agent.Server` through
  `Session.Approvals`.

  A question may carry a list of options. The UI then offers them as a numbered
  menu instead of an empty input box, and `multiple` decides whether the reader
  picks one (digit answers immediately) or toggles several and confirms with
  Enter. Typing a free-text answer stays available either way, so an option list
  is a shortcut and never a cage.
  """
  @behaviour Troupe.Tool

  @max_options 9

  @typedoc "One offered answer: what it says, and the detail shown under it."
  @type option :: %{label: String.t(), description: String.t() | nil}

  @typedoc "A question as the rest of the system sees it, whatever the model sent."
  @type question :: %{
          question: String.t(),
          options: [option()],
          multiple: boolean()
        }

  @impl true
  def name, do: "ask_user"

  @impl true
  def description,
    do:
      "Ask the user a question and wait for the answer. Use it only when you genuinely cannot proceed without a decision from the user. Pass `options` to offer concrete choices (at most #{@max_options}; the user picks by number and can still type something else), and `multiple: true` when several may be chosen at once."

  @impl true
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

  @impl true
  def default_permission, do: :auto

  @impl true
  def run(_args, _ctx), do: {:error, "ask_user is executed by the agent"}

  @doc "The largest number of options a question may offer, one per digit key."
  @spec max_options() :: pos_integer()
  def max_options, do: @max_options

  @doc """
  Normalises whatever the model sent into `t:question/0`.

  Models are loose with this shape: options arrive as bare strings, as objects
  under `label`/`name`/`value`/`text`, with blank or duplicate labels, or in
  their hundreds. Everything is coerced here, once, so no caller downstream has
  to defend itself — and so the event log, the TUI and the answer that goes back
  to the model all agree on what was offered.
  """
  @spec normalize(map()) :: question()
  def normalize(input) when is_map(input) do
    %{
      question: input |> Map.get("question", "") |> to_string(),
      options: input |> Map.get("options") |> normalize_options(),
      multiple: truthy?(Map.get(input, "multiple"))
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

  defp normalize_option(label) when is_binary(label),
    do: %{label: one_line(label), description: nil}

  defp normalize_option(option) when is_map(option) do
    label =
      ["label", "name", "value", "text", "title"]
      |> Enum.find_value("", fn key ->
        case Map.get(option, key) do
          value when is_binary(value) or is_number(value) -> to_string(value)
          _ -> nil
        end
      end)

    %{label: one_line(label), description: description(option)}
  end

  defp normalize_option(other) when is_number(other),
    do: %{label: to_string(other), description: nil}

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

  # Labels are shown on one row of a menu and echoed into the transcript, so a
  # newline in one would abort the frame that draws it.
  defp one_line(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_other), do: false

  @doc """
  The answer text sent back to the model for a set of chosen labels. Selections
  are rendered as the labels themselves rather than as indices: the model wrote
  the labels and never saw the numbering the UI invented.
  """
  @spec answer_text([String.t()]) :: String.t()
  def answer_text(labels) when is_list(labels), do: Enum.join(labels, ", ")
end
