defmodule Troupe.MCP.Import do
  @moduledoc """
  Reading MCP servers as other tools write them down (Decision 700).

  Every editor and assistant keeps its servers in a JSON file of nearly the same shape:
  Claude Code's `.mcp.json` and Claude Desktop's `claude_desktop_config.json` under
  `mcpServers`, Cursor's `mcp.json` the same, VS Code's `.vscode/mcp.json` under
  `servers` with an `inputs` list beside it. Each entry is a `command` with `args` and
  `env`, or a `url` with `headers`. opencode's `opencode.json` keeps them under `mcp`, a
  `command` list and an `environment`, or a `url` and `headers`, and `enabled: false` for
  one that is off. Troupe's own `mcp.json` (`Troupe.MCP.Local`) is the `mcpServers` shape
  plus an `include` list, so a file Troupe wrote is one it can import and one another
  tool can read.

  What comes out is one entry per server in the shape Troupe stores: string keys,
  `command`, `args`, `env`, `cd`, `url`, `headers`, `permission`, `timeout_ms`,
  `disabled`. The other tools' placeholders are translated where Troupe has a spelling
  for them — `${VAR}` and `${env:VAR}` become `{env:VAR}`, which `Troupe.Config` reads
  and refuses when unset rather than sending an empty string — and refused where it has
  none: a VS Code `${input:…}` is a prompt only VS Code can answer, and an opencode
  `{file:…}` a file only opencode reads, so that server is skipped and said so, never
  imported with a hole in it.

  A copy (`copy: true`, Decision 820) is written into Troupe's own `mcp.json`, which
  people link, copy and commit, so a header's value written out in the other tool's file
  is not copied: the header is written as the `{env:VAR}` that reads it, keeping a
  `Bearer ` in front, and a warning names the variable to set. Nothing here touches a
  file.
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
  @file_reference ~r/\{file:[^}]*\}/
  @reference ~r/\{env:[A-Za-z_][A-Za-z0-9_]*\}/
  # The schemes a credential is written after, which stay written when it is not copied.
  @scheme ~r/^(Bearer|Basic|Token) +(?=\S)/i

  @doc """
  Parse a file's text: JSON, with the comments and trailing commas VS Code and Cursor
  allow. `{:error, reason}` only when the text is not a server file at all.

  `partial: true` reads a layer file of Troupe's own, where an entry may carry only
  the fields it changes over a lower layer — `{"disabled": true}` — and the transport
  is checked after the layers are merged, not here. `copy: true` reads a file to copy
  into Troupe's own: a header's value is not copied but read from the environment, and
  a warning says from which variable.
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
  Cursor, Troupe), `servers` (VS Code), `mcp` (opencode), or a bare map of name to entry.
  """
  @spec from_map(term(), keyword()) :: {:ok, parsed()} | {:error, String.t()}
  def from_map(map, opts \\ [])

  def from_map(%{"mcpServers" => servers}, opts) when is_map(servers),
    do: {:ok, servers(servers, opts)}

  def from_map(%{"servers" => servers}, opts) when is_map(servers),
    do: {:ok, servers(servers, opts)}

  # Not a bare map with one server named `mcp`, which has a command or a url of its own.
  def from_map(%{"mcp" => servers}, opts)
      when is_map(servers) and not is_map_key(servers, "command") and
             not is_map_key(servers, "url") do
    translated = Map.new(servers, fn {name, entry} -> {name, opencode(entry)} end)
    {:ok, servers(translated, opts)}
  end

  def from_map(map, opts) when is_map(map) do
    if map != %{} and Enum.all?(map, fn {_name, entry} -> is_map(entry) end),
      do: {:ok, servers(map, opts)},
      else: {:error, "no mcpServers object in the file"}
  end

  def from_map(_other, _opts), do: {:error, "the file is not a JSON object"}

  @doc """
  One server's entry as Troupe stores it, or why it cannot be.

  `command` with `args`, `env` and a working directory (`cwd` as VS Code and Cursor
  spell it, `cd` as Troupe does), or `url` with `headers` (Decision 820) and an `oauth`
  sign-in (Decision 741); `disabled` as Cursor and Cline write it; `permission` and
  `timeout_ms` as Troupe does. `type` is read and dropped: the transport follows from
  which of `command` and `url` is set. With `partial: true` an entry may name neither,
  and one that names both is still refused.
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
         {:ok, env} <- string_map(raw, "env"),
         {:ok, headers} <- string_map(raw, "headers"),
         {:ok, oauth} <- oauth(raw) do
      entry =
        %{
          "command" => command,
          "args" => args,
          "env" => env,
          "cd" => first_string(raw, ["cd", "cwd"]),
          "url" => url,
          "headers" => headers,
          "oauth" => oauth,
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

        {entry, copied} =
          if Keyword.get(opts, :copy, false), do: headers_from_env(name, entry), else: {entry, []}

        %{
          acc
          | servers: Map.put(acc.servers, name, entry),
            warnings: acc.warnings ++ renamed ++ warnings ++ copied
        }

      {:error, reason} ->
        %{acc | skipped: acc.skipped ++ [%{name: raw_name, reason: reason}]}
    end
  end

  # A `${input:…}` anywhere in the entry is a value only VS Code could ask for, and a
  # `{file:…}` one only opencode reads.
  defp inputs_free(raw) do
    text = Jason.encode!(raw)

    cond do
      String.match?(text, @input) ->
        {:error, "uses a ${input:…} placeholder only VS Code can fill in"}

      String.match?(text, @file_reference) ->
        {:error, "uses a {file:…} reference only opencode reads; write it as {env:VAR}"}

      true ->
        :ok
    end
  end

  # opencode's entry in the shape the others write: the program and its arguments are
  # one `command` list, the variables `environment`, and `enabled: false` is off. Its
  # `timeout` is how long the tools are waited for, not a call, and an `oauth: false`
  # says no sign-in; neither is read.
  defp opencode(%{} = entry) do
    {command, args} =
      case entry["command"] do
        [command | args] -> {command, args}
        other -> {other, entry["args"]}
      end

    entry
    |> Map.drop(["command", "args", "environment", "enabled", "timeout", "type"])
    |> Map.reject(fn {key, value} -> key == "oauth" and value == false end)
    |> Map.merge(%{
      "command" => command,
      "args" => args,
      "env" => entry["environment"] || entry["env"],
      "disabled" => entry["enabled"] == false
    })
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp opencode(other), do: other

  # A copy into Troupe's own `mcp.json` (Decision 820): a header whose value is written
  # out is written as the `{env:VAR}` that reads it, `Bearer ` and the like kept in
  # front so the variable holds the credential alone, and the warning names the
  # variable. One that already reads the environment is kept as it is.
  defp headers_from_env(name, %{"headers" => headers} = entry) do
    {headers, notes} =
      headers
      |> Enum.sort()
      |> Enum.map_reduce([], fn {header, value}, notes ->
        if value != "" and not Regex.match?(@reference, value) do
          var = variable(name, header)
          {scheme, what} = scheme(value)
          written = scheme <> "{env:#{var}}"

          note =
            "#{name}: the header #{header} is copied as #{written}, not as its value; " <>
              "set #{var} to the #{what} in the file it came from"

          {{header, written}, notes ++ [note]}
        else
          {{header, value}, notes}
        end
      end)

    {%{entry | "headers" => Map.new(headers)}, notes}
  end

  defp headers_from_env(_name, entry), do: {entry, []}

  defp scheme(value) do
    case Regex.run(@scheme, value) do
      [prefix, _scheme] -> {prefix, "credential after #{String.trim(prefix)}"}
      nil -> {"", "value"}
    end
  end

  # `<SERVER>_<HEADER>`, as an environment variable is spelled: `github` and
  # `X-Api-Key` are `GITHUB_X_API_KEY`.
  defp variable(name, header) do
    var =
      (name <> "_" <> header)
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9]+/, "_")
      |> String.trim("_")

    if var =~ ~r/^[0-9]/, do: "MCP_" <> var, else: var
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

  # `env`, or `headers`: names to strings, a number or a boolean written as one.
  defp string_map(raw, key) do
    map = Map.get(raw, key, %{})

    cond do
      not is_map(map) -> {:error, "#{key} is not a map"}
      not Enum.all?(map, &scalar?/1) -> {:error, "#{key} is not a map of strings"}
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

  # A server that wants the person signed in (Decision 741): the client id registered
  # for it and the overrides, in Troupe's spelling — `clientId`, `redirectUri` and a
  # `callbackPort` as some tools write them are read too. What is checked here is the
  # shape; whether it is enough to sign in with is `Troupe.MCP.OAuth.config/1`'s, once
  # the layers are merged.
  defp oauth(%{"oauth" => nil}), do: {:ok, nil}

  defp oauth(%{"oauth" => %{} = oauth}) do
    with {:ok, scopes} <- scopes(oauth) do
      {:ok,
       %{
         "client_id" => first_string(oauth, ["client_id", "clientId"]),
         "scopes" => scopes,
         "redirect_uri" =>
           first_string(oauth, ["redirect_uri", "redirectUri"]) || callback(oauth),
         "resource" => if(oauth["resource"] == false, do: false),
         "issuer" => first_string(oauth, ["issuer"])
       }
       |> Map.reject(fn {_key, value} -> value in [nil, []] end)}
    end
  end

  defp oauth(%{"oauth" => _other}), do: {:error, "oauth is not an object"}
  defp oauth(_raw), do: {:ok, nil}

  defp scopes(oauth) do
    case oauth["scopes"] || oauth["scope"] do
      nil ->
        {:ok, nil}

      text when is_binary(text) ->
        {:ok, String.split(text)}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, "oauth.scopes is not a list of strings"}

      _other ->
        {:error, "oauth.scopes is not a list of strings"}
    end
  end

  defp callback(oauth) do
    case oauth["callback_port"] || oauth["callbackPort"] do
      port when is_integer(port) and port in 1..65_535 -> "http://localhost:#{port}/callback"
      _none -> nil
    end
  end

  defp permission(%{"permission" => "auto"}), do: "auto"
  defp permission(_raw), do: nil

  defp timeout(%{"timeout_ms" => ms}) when is_integer(ms) and ms > 0, do: ms
  defp timeout(_raw), do: nil

  defp warnings(name, raw, _entry) do
    # Claude Code's command that prints headers when a server is connected.
    dropped =
      if is_binary(raw["headersHelper"]),
        do: [
          "#{name}: headersHelper is a command Troupe does not run; " <>
            "give the headers it prints as headers, a secret as {env:VAR}"
        ],
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
