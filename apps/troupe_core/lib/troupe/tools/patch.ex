defmodule Troupe.Tools.Patch do
  @moduledoc """
  Revise a document on the session's scratchpad in place (issue #616): replace an exact
  span of it, or add to its end, without sending the whole of it again.

  `show` writes a document whole, and showing it again under its name replaces it, so a
  revision of a long plan was the whole plan again as one call's arguments: sent on every
  later call until a compaction, and cut at the reply's output cap when it was long
  enough. A patch carries the change. With no `old_string` it adds to the end, which is
  also how a document too long for one reply is written: `show` its start, then `patch`
  the rest on, a part a call. `Troupe.Scratch.patch/4` holds the rules; each revision is
  the document's next version, a `scratch_updated` like a `show`'s, so a client shows the
  whole document revised.

  Offered wherever `show` is, on every call and every model: it is part of the tools,
  which are the front of every prompt, so it is never offered on some calls and not
  others. Its description is short for the same reason.
  """

  @behaviour Troupe.Tool

  alias Troupe.{Scratch, Tool}

  @impl Troupe.Tool
  def name, do: "patch"

  @impl Troupe.Tool
  def description do
    """
    Revise a document shown beside the chat, in place: replace old_string, which must
    appear in it exactly once, with new_string, or with no old_string add new_string to
    its end (how a long document goes in parts). The person sees it whole.
    """
  end

  # As few words as a model needs: the whole of it is sent on every call.
  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "The document's name, e.g. plan.md."},
        "old_string" => %{"type" => "string"},
        "new_string" => %{"type" => "string"}
      },
      "required" => ["name", "new_string"]
    }
  end

  # It writes only the session's own scratchpad, as `show` does.
  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, raw} <- Tool.fetch_string(args, "name"),
         {:ok, new} <- Tool.fetch_string(args, "new_string"),
         {:ok, old} <- old_string(args),
         {:ok, name} <- Scratch.name(raw),
         {:ok, document} <- Scratch.patch(ctx, name, old, new) do
      {:ok,
       "Revised #{document.path} (#{document.size} bytes, version #{document.version}) " <>
         "beside the chat, where the person sees it whole. Once it is done, reply in a few " <>
         "sentences that name #{document.name}, and do not repeat it."}
    end
  end

  defp old_string(args) do
    case Map.get(args, "old_string") do
      nil -> {:ok, nil}
      old when is_binary(old) -> {:ok, old}
      other -> {:error, {:invalid_args, "old_string must be a string, got #{inspect(other)}"}}
    end
  end
end
