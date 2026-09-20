defmodule Troupe.Tools.Output do
  @moduledoc """
  Capping tool output.

  Every tool that can produce unbounded text goes through here. Truncation is
  announced in the text itself, because a model that cannot tell it got a partial
  answer will confidently reason from it.

  The three-argument forms keep what was cut (Decision 650): the full text becomes a
  blob of the session and the marker names the `read_output` call that pages it back,
  so an agent that needs line 900 of a test run does not run the suite again. The
  two-argument forms are for output that is cheap to produce again — a file read with
  the next offset returns the same bytes.
  """

  alias Troupe.Session.Blobs
  alias Troupe.Tools.ReadOutput

  @doc "Trim text to `limit` bytes, keeping the head and saying what was dropped."
  @spec cap(String.t(), pos_integer()) :: String.t()
  def cap(text, limit) when byte_size(text) <= limit, do: text

  def cap(text, limit) do
    kept = binary_part(text, 0, limit)
    dropped = byte_size(text) - limit

    # Cut back to the last newline so the truncation never lands mid-line.
    kept =
      case :binary.matches(kept, "\n") do
        [] -> kept
        matches -> binary_part(kept, 0, matches |> List.last() |> elem(0))
      end

    kept <> "\n\n[truncated: #{dropped} more bytes. Narrow the request to see the rest.]"
  end

  @doc "`cap/2`, keeping the full text for `read_output`; the marker resumes after the kept lines."
  @spec cap(String.t(), pos_integer(), Troupe.Tool.Ctx.t()) :: String.t()
  def cap(text, limit, _ctx) when byte_size(text) <= limit, do: text

  def cap(text, limit, ctx) do
    capped = cap(text, limit)
    kept_lines = capped |> String.split("\n\n[truncated:") |> hd() |> count_lines()

    case keep(ctx, text) do
      {:ok, id} -> capped <> "\n" <> ReadOutput.marker(id, kept_lines + 1)
      :error -> capped
    end
  end

  @doc "Cap text taken from the *end* of a stream, such as shell output."
  @spec cap_tail(String.t(), pos_integer()) :: String.t()
  def cap_tail(text, limit) when byte_size(text) <= limit, do: text

  def cap_tail(text, limit) do
    dropped = byte_size(text) - limit
    kept = binary_part(text, dropped, limit)

    kept =
      case :binary.match(kept, "\n") do
        :nomatch -> kept
        {pos, len} -> binary_part(kept, pos + len, byte_size(kept) - pos - len)
      end

    "[truncated: #{dropped} earlier bytes omitted]\n\n" <> kept
  end

  @doc "`cap_tail/2`, keeping the full text for `read_output`; the marker resumes at line 1."
  @spec cap_tail(String.t(), pos_integer(), Troupe.Tool.Ctx.t()) :: String.t()
  def cap_tail(text, limit, _ctx) when byte_size(text) <= limit, do: text

  def cap_tail(text, limit, ctx) do
    case keep(ctx, text) do
      {:ok, id} -> ReadOutput.marker(id, 1) <> "\n" <> cap_tail(text, limit)
      :error -> cap_tail(text, limit)
    end
  end

  @doc "Store the full text of a cut result as a blob of the session; its digest is the id."
  @spec keep(Troupe.Tool.Ctx.t(), String.t()) :: {:ok, String.t()} | :error
  def keep(%{session_id: sid, workspace: %{root_real: root}}, text) when is_binary(sid) do
    {:ok, Blobs.store(sid, root, text)}
  rescue
    _ -> :error
  end

  def keep(_ctx, _text), do: :error

  defp count_lines(text), do: text |> String.split("\n") |> length()
end
