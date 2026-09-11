defmodule Troupe.Tools.Remember do
  @moduledoc """
  Writes to the project brief (`.troupe/memory.md`) through `Session.Memory`.

  `:auto` although it writes: the only file it can reach is the brief, the model
  cannot name a path, and asking for approval on every learned fact would mean
  the brief never gets written.
  """
  @behaviour Troupe.Tool

  alias Troupe.Memory
  alias Troupe.Session

  @sections ~w(overview layout commands conventions note)

  @impl true
  def name, do: "remember"

  @impl true
  def description do
    """
    Write something durable about this codebase to the shared project brief (.troupe/memory.md), so later agents start knowing it instead of working it out again.

    Record only what stays true beyond your current task: an architectural rule, a build or test incantation, a non-obvious invariant, where a subsystem lives. Never record task-specific state, findings about code you are mid-way through changing, or anything you have not verified.

    `section: "note"` appends one dated line and is what you usually want. The other sections (overview, layout, commands, conventions) replace that section wholesale; use them only when you have surveyed enough to write the whole section.

    The brief is read into the system prompt when an agent starts, so what you write here reaches the next agent, not your own current turn.
    """
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "section" => %{
          "type" => "string",
          "enum" => @sections,
          "description" => "\"note\" appends one line; the others replace that section"
        },
        "text" => %{"type" => "string", "description" => "What to record, in plain prose"}
      },
      "required" => ["section", "text"]
    }
  end

  @impl true
  def default_permission, do: :auto

  @impl true
  def run(%{"section" => section, "text" => text}, ctx)
      when is_binary(section) and is_binary(text) do
    cond do
      String.trim(text) == "" ->
        {:error, "text is empty; there is nothing to remember"}

      String.downcase(section) not in @sections ->
        {:error, "unknown section #{section}; use one of: #{Enum.join(@sections, ", ")}"}

      true ->
        record(String.downcase(section), text, ctx)
    end
  end

  def run(_args, _ctx), do: {:error, "remember needs a section and text"}

  @impl true
  def preview(%{"section" => section, "text" => text}, _ctx), do: "#{section}: #{text}"
  def preview(args, _ctx), do: inspect(args)

  defp record("note", text, ctx) do
    reply(Session.Memory.note(ctx.session_id, ctx.agent_path, text), "note added")
  end

  defp record(section, text, ctx) do
    reply(
      Session.Memory.put_section(ctx.session_id, section, text),
      "#{Memory.canonical_titles() |> Enum.find(&(String.downcase(&1) == section))} rewritten"
    )
  end

  defp reply(:ok, message), do: {:ok, "project brief updated: #{message}"}
  defp reply({:error, reason}, _message), do: {:error, reason}
end
