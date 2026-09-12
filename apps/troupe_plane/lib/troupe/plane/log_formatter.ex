defmodule Troupe.Plane.LogFormatter do
  @moduledoc """
  One JSON object per line, for a log pipeline that parses rather than reads.

  An Erlang `:logger` formatter — `format/2` over the log event and the formatter's
  configuration, giving back chardata — installed on the default handler from
  `runtime.exs` when `TROUPE_LOG_FORMAT=json`. Nothing about what is logged changes;
  only the shape of a line does, so the same message can be grepped on a laptop and
  queried in a cluster.

  Each line carries the time, the level, the message and whichever of the configured
  metadata keys the event has — `request_id` from `Plug.RequestId` and `session_id`
  where a session is in play, by default. The rest of the metadata is left out on
  purpose: a line with `pid`, `mfa` and `file` on every event is mostly noise, and a
  key that matters can be added to the list.

  Written against what OTP ships rather than a JSON logging dependency: the contract is
  two functions, and a formatter that cannot render an event must not take the logger
  down with it, so a line that fails to encode becomes a line that says so.
  """

  @default_metadata [:request_id, :session_id]

  @doc """
  Check the formatter's configuration: a map or keyword with an optional `:metadata`
  list of atoms. `:logger` calls this when the handler is installed, so a typo is a
  boot-time error rather than a formatter that quietly logs nothing extra.
  """
  @spec check_config(map() | keyword()) :: :ok | {:error, term()}
  def check_config(config) do
    case metadata_keys(config) do
      keys when is_list(keys) ->
        if Enum.all?(keys, &is_atom/1), do: :ok, else: {:error, {:metadata, keys}}

      other ->
        {:error, {:metadata, other}}
    end
  end

  @doc "Render one log event as a JSON object and a newline."
  @spec format(:logger.log_event(), map() | keyword()) :: IO.chardata()
  def format(%{level: level, msg: msg, meta: meta}, config) do
    line =
      %{
        "time" => time(meta),
        "level" => Atom.to_string(level),
        "msg" => message(msg, meta)
      }
      |> Map.merge(metadata(meta, metadata_keys(config)))

    [Jason.encode_to_iodata!(line), ?\n]
  rescue
    error ->
      [
        Jason.encode_to_iodata!(%{
          "level" => "error",
          "msg" => "troupe: a log event could not be formatted: #{Exception.message(error)}"
        }),
        ?\n
      ]
  end

  defp metadata_keys(config) when is_map(config) do
    Map.get(config, :metadata, @default_metadata)
  end

  defp metadata_keys(config) when is_list(config) do
    Keyword.get(config, :metadata, @default_metadata)
  end

  # `:logger` stamps events in microseconds since the epoch.
  defp time(%{time: micros}) when is_integer(micros) do
    micros |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
  end

  defp time(_meta), do: DateTime.utc_now() |> DateTime.to_iso8601()

  # Elixir's own logging arrives as a string. Reports and format strings are what
  # Erlang libraries and the runtime send; a report is rendered by the callback it came
  # with where there is one, since that is the only thing that knows its shape.
  defp message({:string, chardata}, _meta), do: IO.chardata_to_string(chardata)

  defp message({:report, report}, %{report_cb: callback}) when is_function(callback, 1) do
    {format, args} = callback.(report)
    format |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  defp message({:report, report}, %{report_cb: callback}) when is_function(callback, 2) do
    report
    |> callback.(%{depth: :unlimited, chars_limit: :unlimited, single_line: true})
    |> IO.chardata_to_string()
  end

  defp message({:report, report}, _meta), do: inspect(report)

  defp message({format, args}, _meta) when is_list(args) do
    format |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  defp metadata(meta, keys) do
    for key <- keys, {:ok, value} <- [Map.fetch(meta, key)], into: %{} do
      {Atom.to_string(key), scalar(value)}
    end
  end

  # JSON has strings, numbers and booleans; everything else is shown as Elixir would
  # show it, which is what the reader would have typed to find it.
  defp scalar(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp scalar(nil), do: nil
  defp scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar(value), do: inspect(value)
end
