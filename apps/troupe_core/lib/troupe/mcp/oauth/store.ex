defmodule Troupe.MCP.OAuth.Store do
  @moduledoc """
  Where a person's sign-ins to their own MCP servers are kept (Decision 741):
  `<state>/mcp-oauth.json`, one entry per server and client
  (`Troupe.MCP.OAuth.key/2`).

  The daemon's state directory and not the OS keychain, because the daemon has none in
  this build — the model key is in `config.yaml` for the same reason — and the daemon is
  the process that calls the server, so a keychain only a desktop app could read would
  leave a terminal-only person with no sign-in at all. Not `mcp.json`, which a person
  edits, links and copies between machines, and not the configuration directory, which
  people keep in their dotfiles. Written whole to a file beside it and renamed over it,
  readable by its owner alone where the platform has modes (`%LOCALAPPDATA%` is the
  user's own on Windows), and never kept as a `.previous` copy.

  An entry holds the tokens and what refreshing them needs (the token endpoint, the
  client id, the resource), the account for showing, and the last failure, if the last
  sign-in failed. Nothing else in Troupe reads this file, and nothing writes it but
  `Troupe.MCP.OAuth.Tokens`, which is what keeps two refreshes from racing.
  """

  @file_name "mcp-oauth.json"

  @doc "The file: `<state>/mcp-oauth.json`."
  @spec path(Path.t() | nil) :: Path.t()
  def path(state_dir), do: Path.join(Troupe.Paths.state_dir(state_dir), @file_name)

  @doc "Every entry, by key. A file that is missing or unreadable is no sign-ins."
  @spec all(Path.t() | nil) :: %{String.t() => map()}
  def all(state_dir) do
    with {:ok, text} <- File.read(path(state_dir)),
         {:ok, map} when is_map(map) <- Jason.decode(text) do
      Map.filter(map, fn {_key, entry} -> is_map(entry) end)
    else
      _ -> %{}
    end
  end

  @doc "One server's entry, or `nil`."
  @spec get(Path.t() | nil, String.t()) :: map() | nil
  def get(state_dir, key), do: Map.get(all(state_dir), key)

  @doc "Write one server's entry, or take it out with `nil`."
  @spec put(Path.t() | nil, String.t(), map() | nil) :: :ok | {:error, String.t()}
  def put(state_dir, key, nil), do: save(state_dir, Map.delete(all(state_dir), key))
  def put(state_dir, key, entry), do: save(state_dir, Map.put(all(state_dir), key, entry))

  defp save(state_dir, map) do
    file = path(state_dir)
    tmp = file <> ".tmp"

    # The temporary file is restricted before anything is in it, so there is no moment
    # at which the tokens sit in a file anybody else could read.
    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(tmp, ""),
         :ok <- restrict(tmp),
         :ok <- File.write(tmp, Jason.encode!(map, pretty: true) <> "\n"),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, reason} ->
        {:error, "could not write #{Troupe.Paths.display(file)}: #{:file.format_error(reason)}"}
    end
  end

  defp restrict(path) do
    case :os.type() do
      {:unix, _} -> File.chmod(path, 0o600)
      _ -> :ok
    end
  end
end
