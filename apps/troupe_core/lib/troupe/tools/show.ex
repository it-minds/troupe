defmodule Troupe.Tools.Show do
  @moduledoc """
  Show the person a document beside the chat: the session's scratchpad (issue #472,
  Decision 870).

  A plan, a report or a table written here is not a wall of text in the transcript: the
  clients show it apart, as a card where the call was and a pane or panel that holds it,
  and calling it again under the same name replaces it, so a plan is revised rather than
  printed twice. `Troupe.Scratch` holds the rules; this is the model's side of them.

  Offered to every agent that has every tool, and to the built-in primaries that name it,
  on every call and every model: it is part of the tools, which are the start of every
  prompt, so it is never offered on some calls and not others (Decision 867). Its
  description is short for the same reason: every call sends it.
  """

  @behaviour Troupe.Tool

  alias Troupe.{Scratch, Tool}

  @impl Troupe.Tool
  def name, do: "show"

  @impl Troupe.Tool
  def description do
    """
    Show the person a document beside the chat: a plan, report, comparison, Mermaid
    diagram or table they will read, instead of a long answer in the chat, which then
    stays short and names it. The same name again replaces it.
    """
  end

  # As few words as a model needs: the whole of it is sent on every call.
  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "A file name, e.g. plan.md."},
        "title" => %{"type" => "string"},
        "kind" => %{"type" => "string", "enum" => Scratch.kinds()},
        "content" => %{"type" => "string"}
      },
      "required" => ["name", "title", "content"]
    }
  end

  # It writes only the session's own scratchpad, which nothing reads but the clients.
  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, raw} <- Tool.fetch_string(args, "name"),
         {:ok, title} <- Tool.fetch_string(args, "title"),
         {:ok, content} <- Tool.fetch_string(args, "content"),
         {:ok, name} <- Scratch.name(raw),
         {:ok, kind} <- Scratch.kind(Map.get(args, "kind")),
         {:ok, document} <-
           Scratch.write(ctx, %{name: name, kind: kind, title: title, content: content}) do
      {:ok,
       "Showed #{document.path} (#{document.size} bytes, version #{document.version}) beside " <>
         "the chat. Keep the reply short and name it."}
    end
  end
end
