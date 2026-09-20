defmodule Troupe.Tools.ReadOutput do
  @moduledoc """
  Page through the full output of an earlier tool call that had to be cut.

  `shell` and `grep` are neither cheap nor idempotent: without somewhere to put what was
  omitted, an agent that needed line 900 of a test run would have to run the suite
  again. So a capped result keeps its full text as a blob of the session
  (`Troupe.Tools.Output.keep/2`, Decision 650) and its marker names the call that pages
  it back. Ids are the blob's digest, so a path is never built from anything the model
  typed. `read_file` is not kept: reading again with the next offset returns the same
  bytes.
  """

  @behaviour Troupe.Tool

  alias Troupe.Session.Blobs
  alias Troupe.Tool

  @default_limit 200
  @id ~r/^sha256:[0-9a-f]{64}$/

  @impl Troupe.Tool
  def name, do: "read_output"

  @impl Troupe.Tool
  def description do
    "Page through the full output of an earlier tool call that was truncated. `id` is " <>
      "the identifier in the truncation marker (`sha256:…`); `offset` is the 1-based first " <>
      "line and `limit` the number of lines (default #{@default_limit}). Use this instead " <>
      "of running an expensive or non-idempotent command again."
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string", "description" => "The id from the truncation marker."},
        "offset" => %{"type" => "integer", "description" => "First line to return (1-based)."},
        "limit" => %{"type" => "integer", "description" => "Maximum number of lines."}
      },
      "required" => ["id"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, id} <- Tool.fetch_string(args, "id"),
         :ok <- check_id(id),
         {:ok, text} <- fetch(ctx, id) do
      offset = max(Tool.fetch_int(args, "offset", 1) || 1, 1)
      limit = max(Tool.fetch_int(args, "limit", @default_limit) || @default_limit, 1)
      {:ok, page(text, id, offset, limit)}
    end
  end

  @doc "The marker a capped result carries, naming the call that pages the rest."
  @spec marker(String.t(), pos_integer()) :: String.t()
  def marker(id, offset), do: "[full output kept. Call #{call(id, offset)} for more.]"

  defp call(id, offset),
    do: ~s|read_output(id: "#{id}", offset: #{offset}, limit: #{@default_limit})|

  defp check_id(id), do: if(Regex.match?(@id, id), do: :ok, else: {:error, "not an output id: #{id}"})

  defp fetch(ctx, id) do
    case Blobs.read(ctx.session_id, ctx.workspace.root_real, id) do
      {:ok, text, _size} -> {:ok, text}
      {:error, :not_found} -> {:error, "no kept output #{id} (it may be from another session)"}
    end
  end

  defp page(text, id, offset, limit) do
    lines = String.split(text, "\n")
    total = length(lines)
    shown = lines |> Enum.drop(offset - 1) |> Enum.take(limit)
    last = min(offset + limit - 1, total)
    body = Enum.join(shown, "\n")

    if last >= total do
      body
    else
      body <>
        "\n[… lines #{last + 1}–#{total} of #{total} omitted. Call #{call(id, last + 1)} for more.]"
    end
  end
end
