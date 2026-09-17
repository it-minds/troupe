defmodule Troupe.Session.Outputs do
  @moduledoc """
  The full text of every tool result that had to be cut, kept for the rest of the
  session under `<session dir>/outputs/<id>.txt` and paged back by the
  `read_output` tool.

  Its reason to exist is that `shell` and `web_fetch` are neither cheap nor
  idempotent: without somewhere to put what was omitted, an agent that needed
  line 900 of a test run would have to run the suite again. File reads are not
  stored — `read_file` with the next offset returns the same bytes.
  """

  use GenServer

  alias Troupe.{Paths, Session}
  alias Troupe.Tool.Bound

  defstruct [:dir]

  def start_link(%{session_id: sid} = opts) do
    GenServer.start_link(__MODULE__, opts, name: Session.via(sid, :outputs))
  end

  @doc "Stores `text` and returns the id the retrieval call quotes."
  @spec save(String.t(), String.t()) :: {:ok, String.t()} | :error
  def save(sid, text) when is_binary(text) do
    case Session.whereis(sid, :outputs) do
      nil -> :error
      pid -> GenServer.call(pid, {:save, text}, :infinity)
    end
  end

  @doc """
  A line window over a stored output, 1-based. Returns the text and the total
  number of lines, so the caller can say what is still outstanding.
  """
  @spec read(String.t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def read(sid, id, offset, limit) do
    case Session.whereis(sid, :outputs) do
      nil -> {:error, "no output store for this session"}
      pid -> GenServer.call(pid, {:read, id, offset, limit}, :infinity)
    end
  end

  @doc """
  Renders a bounded result: content that fit is returned unchanged, and content
  that was cut is stored whole and marked with the call that pages it back.
  """
  @spec store_and_mark(String.t(), String.t(), Bound.result(), pos_integer()) :: String.t()
  def store_and_mark(_sid, _full, {text, nil}, _page), do: text

  def store_and_mark(sid, full, {text, omission}, page) do
    case save(sid, full) do
      {:ok, id} ->
        # `read_output` pages by line. Only a line omission knows where to
        # resume; anything cut by character or by JSON element is read from the
        # top of the stored copy.
        from = if omission.unit == :lines, do: omission.first, else: 1

        Bound.place(
          text,
          omission,
          ~s|Full output saved as #{id}. Call read_output(id: "#{id}", offset: #{from}, limit: #{page}) for more.|
        )

      :error ->
        Bound.place(text, omission, "The full output could not be stored.")
    end
  end

  @impl true
  def init(%{session_id: sid, workspace: ws}) do
    dir = Path.join(Paths.session_dir(ws, sid), "outputs")
    File.mkdir_p!(dir)
    {:ok, %__MODULE__{dir: dir}}
  end

  @impl true
  def handle_call({:save, text}, _from, %__MODULE__{} = s) do
    id = unique_id(s.dir)

    case File.write(Path.join(s.dir, id <> ".txt"), text) do
      :ok -> {:reply, {:ok, id}, s}
      {:error, _} -> {:reply, :error, s}
    end
  end

  def handle_call({:read, id, offset, limit}, _from, %__MODULE__{} = s) do
    {:reply, do_read(s.dir, id, offset, limit), s}
  end

  defp do_read(dir, id, offset, limit) do
    with true <- valid_id?(id),
         {:ok, text} <- File.read(Path.join(dir, id <> ".txt")) do
      lines = String.split(text, "\n")
      total = length(lines)
      shown = lines |> Enum.drop(offset - 1) |> Enum.take(limit)
      last = min(offset + limit - 1, total)

      body = Enum.join(shown, "\n")

      if last >= total do
        {:ok, body}
      else
        {:ok,
         body <>
           "\n" <>
           Bound.marker(
             %{first: last + 1, last: total, total: total, unit: :lines},
             ~s|Call read_output(id: "#{id}", offset: #{last + 1}, limit: #{limit}) for more.|
           )}
      end
    else
      false -> {:error, "not an output id: #{id}"}
      {:error, _} -> {:error, "no stored output #{id} (it may be from an earlier session)"}
    end
  end

  # Ids are generated here and quoted back by the model, so a path is never
  # built from anything but `out_` and hex.
  defp valid_id?(id) when is_binary(id), do: Regex.match?(~r/^out_[0-9a-f]{4,}$/, id)
  defp valid_id?(_), do: false

  defp unique_id(dir) do
    id = "out_" <> (:crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower))
    if File.exists?(Path.join(dir, id <> ".txt")), do: unique_id(dir), else: id
  end
end
