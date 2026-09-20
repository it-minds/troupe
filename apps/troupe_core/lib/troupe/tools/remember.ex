defmodule Troupe.Tools.Remember do
  @moduledoc """
  Writes to the project brief (`.troupe/memory.md`) through `Troupe.Session.Memory`.

  `:auto` although it writes: the only file it can reach is the brief, the model cannot
  name a path, and asking for approval on every learned fact would mean the brief never
  gets written.
  """

  @behaviour Troupe.Tool

  alias Troupe.Session.Memory
  alias Troupe.Tool

  @sections ~w(overview layout commands conventions note)

  @impl Troupe.Tool
  def name, do: "remember"

  @impl Troupe.Tool
  def description do
    """
    Write something durable about this codebase to the shared project brief (.troupe/memory.md), so later agents start knowing it instead of working it out again.

    Record only what stays true beyond your current task: an architectural rule, a build or test incantation, a non-obvious invariant, where a subsystem lives. Never record task-specific state, findings about code you are mid-way through changing, or anything you have not verified.

    `section: "note"` appends one dated line and is what you usually want. The other sections (overview, layout, commands, conventions) replace that section wholesale; use them only when you have surveyed enough to write the whole section.

    The brief is read into the system prompt when an agent starts, so what you write here reaches the next agent, not your own current turn.
    """
    |> String.trim()
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "section" => %{"type" => "string", "enum" => @sections},
        "text" => %{"type" => "string", "description" => "What to record."}
      },
      "required" => ["section", "text"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, section} <- Tool.fetch_string(args, "section"),
         {:ok, text} <- Tool.fetch_string(args, "text"),
         :ok <- check(section, text),
         :ok <- write(ctx, section, text) do
      {:ok, "project brief updated: #{what(section)}"}
    end
  end

  defp check(section, text) do
    cond do
      section not in @sections -> {:error, "unknown section #{section}; one of #{Enum.join(@sections, ", ")}"}
      String.trim(text) == "" -> {:error, "nothing to remember: text is empty"}
      true -> :ok
    end
  end

  defp write(ctx, "note", text),
    do: Memory.note(ctx.workspace.root_real, Enum.join(ctx.agent_path, "/"), text)

  defp write(ctx, section, text), do: Memory.put_section(ctx.workspace.root_real, section, text)

  defp what("note"), do: "note added"
  defp what(section), do: String.capitalize(section) <> " rewritten"
end
