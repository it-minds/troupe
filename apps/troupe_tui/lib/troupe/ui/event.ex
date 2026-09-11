defmodule Troupe.UI.Event do
  @moduledoc """
  One shape for every event a UI has to render.

  Events reach a UI two ways. `Session.Log` publishes what it persisted, as JSON with
  string keys, and the same records come back verbatim when a UI rebuilds its screen
  from the log. Transient events — deltas, agent state, approvals, notices — are
  published as the terms their publisher built.

  Normalising both into atom-keyed data here means a live screen and one rebuilt from
  the log are folded through identical code, and neither UI has to know which kind of
  event it is looking at.
  """

  alias Troupe.LLM.Message
  alias Troupe.Todo

  @type t :: %{type: atom(), agent_path: [String.t()], data: map()}

  @doc "Normalise a published event, or `nil` if it is not one a UI can render."
  @spec normalize(map()) :: t() | nil
  def normalize(%{type: type, data: data} = event) when is_atom(type) do
    %{
      type: type,
      agent_path: Map.get(event, :agent_path) || ["root"],
      data: normalize_data(type, data)
    }
  end

  def normalize(%{"type" => type, "agent_path" => path, "data" => data}) do
    case safe_type(type) do
      nil -> nil
      atom -> %{type: atom, agent_path: path, data: normalize_data(atom, data)}
    end
  end

  def normalize(_event), do: nil

  # Event types are a closed set defined by this application, so one from a log
  # written by a newer version is skipped rather than crashing a screen.
  defp safe_type(type) do
    String.to_existing_atom(type)
  rescue
    ArgumentError -> nil
  end

  defp normalize_data(:tool_call_started, %{"call_id" => id} = data) do
    %{call_id: id, name: data["name"], args: data["args"] || %{}}
  end

  defp normalize_data(:tool_call_completed, %{"call_id" => id} = data) do
    %{call_id: id, name: data["name"], ok?: data["ok"], content: data["content"] || ""}
  end

  defp normalize_data(:delegation_started, %{"agent" => agent} = data) do
    %{call_id: data["call_id"], agent: agent, task: data["task"], child_path: data["child_path"]}
  end

  defp normalize_data(:todo_updated, %{"items" => items}) do
    %{items: Enum.map(items || [], &Todo.from_json/1)}
  end

  defp normalize_data(:user_input, %{"text" => text} = data) do
    %{source: data["source"] || "user", text: text}
  end

  defp normalize_data(:llm_response, %{"message" => message}) do
    %{text: message |> Message.from_json() |> Message.text()}
  end

  defp normalize_data(:profile_switched, %{"to" => to} = data), do: %{from: data["from"], to: to}
  defp normalize_data(:watch_notice, %{"message" => message}), do: %{message: message}
  defp normalize_data(:llm_error, %{"reason" => reason}), do: %{reason: reason}
  defp normalize_data(:budget_exhausted, %{"limit" => limit}), do: %{limit: limit}

  defp normalize_data(:agent_done, %{"reason" => reason} = data),
    do: %{reason: reason, summary: data["summary"]}

  defp normalize_data(:compacted, %{"summary" => summary}), do: %{summary: summary}

  defp normalize_data(_type, data), do: data
end
