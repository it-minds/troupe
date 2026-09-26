defmodule Troupe.MCP.Import do
  @moduledoc """
  Reading MCP servers as other tools write them down (Decision 700).

  Every editor and assistant keeps its servers in a JSON file of nearly the same shape:
  Claude Code's `.mcp.json` and Claude Desktop's `claude_desktop_config.json` under
  `mcpServers`, Cursor's `mcp.json` the same, VS Code's `.vscode/mcp.json` under
  `servers` with an `inputs` list beside it. Each entry is a `command` with `args` and
  `env`, or a `url`. Troupe's own `mcp.json` (`Troupe.MCP.Local`) is the same
  `mcpServers` shape plus an `include` list, so a file Troupe wrote is one it can import
  and one another tool can read.

  What comes out is one entry per server in the shape Troupe stores: string keys,
  `command`, `args`, `env`, `cd`, `url`, `permission`, `timeout_ms`, `disabled`. The
  other tools' placeholders are translated where Troupe has a spelling for them —
  `${VAR}` and `${env:VAR}` become `{env:VAR}`, which `Troupe.Config` reads and refuses
  when unset rather than sending an empty string — and refused where it has none: a VS
  Code `${input:…}` is a prompt only VS Code can answer, so that server is skipped and
  said so, never imported with a hole in it. Nothing here touches a file.
  """

  alias Troupe.Config.JSONC

  @typedoc "One server as Troupe stores it, string-keyed, ready to be written or started."
  @type entry :: %{String.t() => term()}

  @typedoc "What a parse says: the servers it read, and the ones it could not, with why."
  @type parsed :: %{
          servers: %{String.t() => entry()},
          skipped: [%{name: String.t(), reason: String.t()}],
          warnings: [String.t()]
        }

  @name ~r/^[a-z0-9][a-z0-9_-]*$/
  # `${VAR}`, `${env:VAR}` and Claude Code's `${VAR:-default}`, whose default is dropped.
  @placeholder ~r/\$\{(?:env:)?([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/
  @input ~r/\$\{input:[^}]*\}/

  @doc """
  Parse a file's text: JSON, with the comments and trailing commas VS Code and Cursor
  allow. `{:error, reason}` only when the text is not a server file at all.

  `partial: true` reads a layer file of Troupe's own, where an entry may carry only
  the fields it changes over a lower layer — `{"disabled": true}` — and the transport
  is checked after the layers are merged, not here.
  """
  @spec parse(String.t(), keyword()) :: {:ok, parsed()} | {:error, String.t()}
  def parse(text, opts \\ []) when is_binary(text) do
    case JSONC.decode(text) do
      {:ok, decoded} -> from_map(decoded, opts)
      {:error, %Jason.DecodeError{} = error} -> {:error, "not JSON: " <> Exception.message(error)}
      {:error, other} -> {:error, "not JSON: #{inspect(other)}"}
    end
  end

  @doc """
  The servers in a decoded document: under `mcpServers` (Claude Code, Claude Desktop,
  Cursor, Troupe), `servers` (VS Code), or a bare map of name to entry.
  """
  @spec from_map(term(), keyword()) :: {:ok, parsed()} | {:error, String.t()}
  def from_map(map, opts \\ [])

  def from_map(%{"mcpServers" => servers}, opts) when is_map(servers),
    do: {:ok, servers(servers, opts)}

  def from_map(%{"servers" => servers}, opts) when is_map(servers),
    do: {:ok, servers(servers, opts)}

  def from_map(map, opts) when is_map(map) do
    if map != %{} and Enum.all?(map, fn {_name, entry} -> is_map(entry) end),
      do: {:ok, servers(map, opts)},
      else: {:error, "no mcpServers object in the file"}
  end

  def from_map(_other, _opts), do: {:error, "the file is not a JSON object"}

  @doc """
  One server's entry as Troupe stores it, or why it cannot be.

  `command` with `args`, `env` and a working directory (`cwd` as VS Code and Cursor
  spell it, `cd` as Troupe does), or `url`; `disabled` as Cursor and Cline write it;
  `permission` and `timeout_ms` as Troupe does. `type` and `headers` are read and
  dropped: the transport follows from which of `command` and `url` is set, and a header
  is a credential this slice does not carry. With `partial: true` an entry may name
  neither, and one that names both is still refused.
  """
  @spec normalize(String.t(), term(), keyword()) ::
          {:ok, entry(), [String.t()]} | {:error, String.t()}
  def normalize(name, raw, opts \\ [])

  def normalize(name, raw, opts) when is_map(raw) do
    with :ok <- inputs_free(raw),
         {:ok, command} <- string_or_nil(raw, "command"),
         {:ok, url} <- string_or_nil(raw, "url"),
         :ok <- one_transport(command, url, Keyword.get(opts, :partial, false)),
         {:ok, args} <- strings(raw, "args"),
         {:ok, env} <- env(raw) do
      entry =
        %{
          "command" => command,
          "args" => args,
          "env" => env,
          "cd" => first_string(raw, ["cd", "cwd"]),
          "url" => url,
          "permission" => permission(raw),
          "timeout_ms" => timeout(raw),
          "disabled" => raw["disabled"] == true
        }
        |> Map.reject(fn {_key, value} -> value in [nil, [], %{}, false] end)

      {:ok, entry, warnings(name, raw, entry)}
    end
  end

  def normalize(_name, _raw, _opts), do: {:error, "is not an object"}

  @doc """
  Whether a name is one Troupe can spell a tool with: `mcp.<server>.<tool>` splits on
  the first dot after the prefix, so a server's name has none.
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@name, name)
  def valid_name?(_name), do: false

  @doc """
  A name as Troupe can use it: lower case, with anything it does not allow written as
  a dash, so `My Server` imports as `my-server`. Unchanged when it was already fine.
  """
  @spec sanitize_name(String.t()) :: String.t()
  def sanitize_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "server"
      clean -> clean
    end
  end

  @doc """
  The other tools' placeholders in Troupe's spelling: `${VAR}` and `${env:VAR}` become
  `{env:VAR}`. Applied to every string an entry carries.
  """
  @spec translate(term()) :: term()
  def translate(value) when is_binary(value),
    do: Regex.replace(@placeholder, value, fn _match, var, _default -> "{env:#{var}}" end)

  def translate(list) when is_list(list), do: Enum.map(list, &translate/1)

  def translate(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, translate(value)} end)

  def translate(other), do: other

  # -- helpers ----------------------------------------------------------------------

  defp servers(map, opts) do
    map
    |> Enum.sort()
    |> Enum.reduce(%{servers: %{}, skipped: [], warnings: []}, &collect(&1, &2, opts))
  end

  defp collect({raw_name, raw}, acc, opts) do
    raw_name = to_string(raw_name)
    name = sanitize_name(raw_name)

    case normalize(name, raw, opts) do
      {:ok, entry, warnings} ->
        renamed = if name == raw_name, do: [], else: ["#{raw_name} is imported as #{name}"]

        %{
          acc
          | servers: Map.put(acc.servers, name, entry),
            warnings: acc.warnings ++ renamed ++ warnings
        }

      {:error, reason} ->
        %{acc | skipped: acc.skipped ++ [%{name: raw_name, reason: reason}]}
    end
  end

  # A `${input:…}` anywhere in the entry is a value only VS Code could ask for.
  defp inputs_free(raw) do
    if raw |> Jason.encode!() |> String.match?(@input),
      do: {:error, "uses a ${input:…} placeholder only VS Code can fill in"},
      else: :ok
  end

  defp one_transport(nil, nil, false), do: {:error, "has neither a command nor a url"}
  defp one_transport(nil, nil, true), do: :ok
  defp one_transport(_command, nil, _partial?), do: :ok
  defp one_transport(nil, _url, _partial?), do: :ok

  defp one_transport(_command, _url, _partial?),
    do: {:error, "has both a command and a url; keep the one it is"}

  defp string_or_nil(raw, key) do
    case Map.get(raw, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, translate(value)}
      _other -> {:error, "#{key} is not a string"}
    end
  end

  defp strings(raw, key) do
    case Map.get(raw, key, []) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, translate(list)},
          else: {:error, "#{key} is not a list of strings"}

      _other ->
        {:error, "#{key} is not a list"}
    end
  end

  defp env(raw) do
    map = Map.get(raw, "env", %{})

    cond do
      not is_map(map) -> {:error, "env is not a map"}
      not Enum.all?(map, &scalar?/1) -> {:error, "env is not a map of strings"}
      true -> {:ok, Map.new(map, fn {k, v} -> {to_string(k), translate(to_string(v))} end)}
    end
  end

  defp scalar?({_key, value}), do: is_binary(value) or is_number(value) or is_boolean(value)

  defp first_string(raw, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(raw, key) do
        value when is_binary(value) and value != "" -> translate(value)
        _ -> nil
      end
    end)
  end

  defp permission(%{"permission" => "auto"}), do: "auto"
  defp permission(_raw), do: nil

  defp timeout(%{"timeout_ms" => ms}) when is_integer(ms) and ms > 0, do: ms
  defp timeout(_raw), do: nil

  defp warnings(name, raw, _entry) do
    dropped =
      if is_map(raw["headers"]) and raw["headers"] != %{},
        do: ["#{name}: headers are not carried into a Troupe server yet, and were dropped"],
        else: []

    defaults =
      raw
      |> Jason.encode!()
      |> then(&Regex.scan(@placeholder, &1))
      |> Enum.filter(fn
        [_match, _var, default] -> default != ""
        _ -> false
      end)
      |> Enum.map(fn [_match, var, _default] ->
        "#{name}: ${#{var}:-…} is read as {env:#{var}}; its default is dropped"
      end)

    Enum.uniq(dropped ++ defaults)
  end
end
