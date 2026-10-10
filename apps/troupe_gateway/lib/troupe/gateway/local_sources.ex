defmodule Troupe.Gateway.LocalSources do
  @moduledoc """
  `mcp.list`, `mcp.add`, `mcp.remove`, `mcp.check` and `skills.list`, `skills.add`,
  `skills.remove`: the person's own MCP servers and skills, over the wire
  (Decision 700). `mcp.sign_in` and `mcp.sign_out`: their sign-in to a server that wants
  them rather than a machine (Decision 741). `mcp.tools` and `mcp.call`: one of their
  servers listed and called outside any session, with their sign-in, for a client that
  offers its tools to a session on a pod (Decision 748).

  The daemon's alone, as the model settings are. The files are the daemon's config
  directory and a workspace on this machine, a pod's servers are its bundle's, and so
  a worker answers `method_not_found`. Both clients manage one set through these, so a
  server imported in the desktop app is on the TUI's `/mcp` page and the other way
  round; the TUI and the GUI hold a form each and never a path of their own.

  What goes back is what a panel shows and nothing a file keeps secret: a server's
  environment travels as the names of its variables, and its headers as their names
  (Decision 820), never their values. A path goes
  back as a person on this platform writes it (`Troupe.Paths.display/1`), since a panel
  prints it; the files themselves are read and written by the paths they had.
  """

  alias Troupe.MCP.{Import, Local, OAuth, Tool, Trust}
  alias Troupe.Paths
  alias Troupe.Protocol.Error
  alias Troupe.Session.MCP, as: LocalMCP
  alias Troupe.Skills

  @type outcome :: {:ok, map()} | {:error, Error.t()}

  @doc "Dispatch one of the eleven, with the daemon already known to be the server."
  @spec call(String.t(), map()) :: outcome()
  def call("mcp.list", params), do: list_servers(params)
  def call("mcp.add", params), do: add_server(params)
  def call("mcp.remove", params), do: remove_server(params)
  def call("mcp.check", params), do: check_server(params)
  def call("mcp.sign_in", params), do: sign_in(params)
  def call("mcp.sign_out", params), do: sign_out(params)
  def call("mcp.tools", params), do: server_tools(params)
  def call("mcp.call", params), do: call_tool(params)
  def call("skills.list", params), do: list_skills(params)
  def call("skills.add", params), do: add_skill(params)
  def call("skills.remove", params), do: remove_skill(params)
  def call(method, _params), do: {:error, Error.new(:method_not_found, %{method: method})}

  # -- servers -------------------------------------------------------------------

  # Every server the layers give the workspace, and — for a session — how each stands
  # there, so one call fills a page. A server the session runs that the files no
  # longer name is listed from the session, since it is still running.
  defp list_servers(params) do
    with {:ok, workspace} <- workspace_of(params) do
      {servers, warnings} = resolve(workspace)
      live = live_status(params["session_id"])
      named = MapSet.new(servers, & &1.name)

      listed =
        Enum.map(servers, &server_json(&1, workspace, live[&1.name])) ++
          for {name, status} <- live, not MapSet.member?(named, name), do: live_json(name, status)

      {:ok, %{"servers" => Enum.sort_by(listed, & &1["name"]), "warnings" => warnings}}
    end
  end

  defp live_status(session_id) when is_binary(session_id) and session_id != "" do
    Map.new(LocalMCP.status(session_id), &{&1.name, &1})
  end

  defp live_status(_none), do: %{}

  defp add_server(params) do
    with {:ok, scope} <- scope_of(params),
         {:ok, workspace} <- workspace_of(params) do
      cond do
        is_binary(params["from"]) and params["from"] != "" ->
          scope
          |> Local.import(workspace, params["from"], params["link"] == true)
          |> imported()

        is_binary(params["name"]) and is_map(params["server"]) ->
          scope
          |> Local.add(workspace, params["name"], params["server"])
          |> written()

        true ->
          invalid("mcp.add takes a file to import (from) or a server to write (name and server)")
      end
    end
  end

  defp written({:ok, result}) do
    {:ok,
     %{
       "name" => result.name,
       "path" => Paths.display(result.path),
       "entry" => entry_json(result.entry),
       "warnings" => result.warnings
     }}
  end

  defp written({:error, reason}), do: invalid(reason)

  defp remove_server(params) do
    with {:ok, scope} <- scope_of(params),
         {:ok, workspace} <- workspace_of(params),
         {:ok, what} <- what_to_remove(params) do
      case Local.remove(scope, workspace, what) do
        {:ok, result} ->
          {:ok, %{"path" => Paths.display(result.path), "removed" => result.removed}}

        {:error, reason} ->
          invalid(reason)
      end
    end
  end

  # Three ways to check: a session's server is read again from its files and started
  # (which is also how one that died is brought back); a workspace's named server, or
  # one given in the request, is run once on its own and stopped.
  defp check_server(%{"session_id" => session_id, "name" => name})
       when is_binary(session_id) and is_binary(name) do
    case LocalMCP.reload(session_id, name) do
      {:ok, status} ->
        {:ok, %{"server" => live_json(name, status)}}

      {:error, :unknown_server} ->
        {:error, Error.new(:not_found, %{kind: "mcp_server", name: name})}

      {:error, :no_session} ->
        {:error, Error.new(:not_found, %{kind: "session", session_id: session_id})}
    end
  end

  defp check_server(%{"name" => name, "server" => raw} = params)
       when is_binary(name) and is_map(raw) do
    with {:ok, workspace} <- workspace_of(params),
         {:ok, entry, _warnings} <- normalized(name, raw) do
      config = Local.to_config(name, entry, workspace)

      record = %{
        name: name,
        layer: :request,
        source: "request",
        config: config,
        disabled?: false,
        fingerprint: Local.fingerprint(config)
      }

      {:ok, %{"server" => record |> LocalMCP.probe(workspace) |> then(&live_json(name, &1))}}
    end
  end

  defp check_server(%{"name" => name} = params) when is_binary(name) do
    with {:ok, workspace} <- workspace_of(params) do
      {servers, _warnings} = resolve(workspace)

      case Enum.find(servers, &(&1.name == name)) do
        nil ->
          {:error, Error.new(:not_found, %{kind: "mcp_server", name: name})}

        server ->
          {:ok, %{"server" => server |> LocalMCP.probe(workspace) |> then(&live_json(name, &1))}}
      end
    end
  end

  defp check_server(_params), do: invalid("mcp.check needs a server's name")

  # A person's sign-in to a server that wants them (Decision 741). The daemon runs it and
  # listens for the browser; the client opens `url` and shows how it stands, from
  # `mcp.list`'s `auth`. A workspace's server is signed in to only once the workspace's
  # servers are trusted: its `oauth` is a cloned repository's, saying where a token of
  # the person's would go.
  defp sign_in(params) do
    with {:ok, server} <- signable(params) do
      case OAuth.sign_in(server.name, server.config.url, server.config.oauth) do
        {:ok, started} ->
          {:ok,
           %{
             "server" => server.name,
             "url" => started.url,
             "redirect_uri" => started.redirect_uri,
             "expires_at" => started.expires_at
           }}

        {:error, why} ->
          invalid(why)
      end
    end
  end

  defp sign_out(params) do
    with {:ok, server} <- signable(params),
         :ok <- server |> sign_in_of() |> OAuth.sign_out() do
      {:ok, %{"server" => server.name, "auth" => auth_json(server)}}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, why} -> invalid(why)
    end
  end

  defp signable(%{"name" => name} = params) when is_binary(name) and name != "" do
    with {:ok, workspace} <- workspace_of(params) do
      {servers, _warnings} = resolve(workspace)

      case Enum.find(servers, &(&1.name == name)) do
        nil -> {:error, Error.new(:not_found, %{kind: "mcp_server", name: name})}
        server -> may_sign_in(server, trust_of(server, workspace))
      end
    end
  end

  defp signable(_params), do: invalid("give the name of the server to sign in to")

  defp may_sign_in(%{config: %{refused: why}}, _trust) when is_binary(why), do: invalid(why)

  defp may_sign_in(%{name: name, config: %{oauth: %{}}}, "pending"),
    do:
      invalid(
        "#{name} is this workspace's, and its servers are not approved here yet; approve them first"
      )

  defp may_sign_in(%{config: %{oauth: %{}, url: url}} = server, _trust) when is_binary(url),
    do: {:ok, server}

  defp may_sign_in(%{name: name}, _trust),
    do: invalid("#{name} takes no sign-in: give its entry an oauth.client_id to sign in to it")

  defp sign_in_of(server),
    do: OAuth.binding(server.name, server.config.url, server.config.oauth, nil)

  # One of the person's servers for a client that offers its tools to a session somewhere
  # else, a pod's (Decision 748): its tools as a session is given them, and a call made
  # here, with the person's sign-in, answered as that session's model reads it. The token
  # stays where the sign-in put it; the session sees names, schemas, arguments and what
  # came back. A server with a `url` only: one that runs a command is a process a local
  # session keeps, and nothing here starts one for somebody else's session.
  defp server_tools(params) do
    with {:ok, server} <- callable(params) do
      {status, tools} = LocalMCP.discover(server)

      {:ok,
       %{
         "server" => server.name,
         "state" => to_string(status.state),
         "error" => status.error,
         "tools" => Enum.map(tools, &tool_json/1)
       }}
    end
  end

  defp tool_json(tool),
    do: %{"name" => tool.remote_name, "description" => tool.description, "schema" => tool.schema}

  # What a session's own tool would answer: the text, or the `sign_in_required` note when
  # the sign-in has run out. A call the server could not take is `unavailable`, saying why.
  defp call_tool(params) do
    with {:ok, server} <- callable(params),
         {:ok, tool} <- fetch(params, "tool"),
         {:ok, arguments} <- arguments_of(params) do
      case server |> LocalMCP.server() |> Tool.invoke(tool, arguments, %{}) do
        {:ok, content} ->
          {:ok, %{"server" => server.name, "tool" => tool, "content" => content}}

        {:error, why} ->
          {:error, Error.new(:unavailable, %{server: server.name, reason: why})}
      end
    end
  end

  defp callable(%{"name" => name} = params) when is_binary(name) and name != "" do
    with {:ok, workspace} <- workspace_of(params) do
      {servers, _warnings} = resolve(workspace)

      case Enum.find(servers, &(&1.name == name)) do
        nil -> {:error, Error.new(:not_found, %{kind: "mcp_server", name: name})}
        server -> may_call(server, trust_of(server, workspace))
      end
    end
  end

  defp callable(_params), do: invalid("give the name of the server")

  defp may_call(%{config: %{refused: why}}, _trust) when is_binary(why), do: invalid(why)
  defp may_call(%{name: name, disabled?: true}, _trust), do: invalid("#{name} is turned off")

  defp may_call(%{name: name}, "pending"),
    do:
      invalid(
        "#{name} is this workspace's, and its servers are not approved here yet; approve them first"
      )

  defp may_call(%{config: %{url: url}} = server, _trust) when is_binary(url), do: {:ok, server}

  defp may_call(%{name: name}, _trust),
    do:
      invalid(
        "#{name} runs a command on this computer; only a server with a url is called outside a session"
      )

  defp arguments_of(params) do
    case Map.get(params, "arguments") do
      nil -> {:ok, %{}}
      arguments when is_map(arguments) -> {:ok, arguments}
      _other -> invalid("arguments must be an object")
    end
  end

  # How the person's sign-in stands: never a token, only the state, whose account it is,
  # and why the last attempt failed.
  defp auth_json(%{config: %{oauth: %{}, url: url}} = server) when is_binary(url) do
    status = server |> sign_in_of() |> OAuth.status()
    %{"state" => to_string(status.state), "account" => status.account, "error" => status.error}
  end

  defp auth_json(_server), do: nil

  defp oauth_json(%{oauth: %{} = oauth}) do
    %{"client_id" => oauth.client_id, "scopes" => oauth.scopes, "issuer" => oauth.issuer}
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp oauth_json(_config), do: nil

  defp normalized(name, raw) do
    case Import.normalize(name, raw) do
      {:ok, entry, warnings} -> {:ok, entry, warnings}
      {:error, reason} -> invalid("#{name} #{reason}")
    end
  end

  defp imported({:ok, result}) do
    {:ok,
     %{
       "path" => Paths.display(result.path),
       "from" => result.from,
       "added" => result.added,
       "skipped" => Enum.map(result.skipped, &%{"name" => &1.name, "reason" => &1.reason}),
       "warnings" => result.warnings,
       "linked" => result.linked
     }}
  end

  defp imported({:error, reason}), do: invalid(reason)

  # `config.yaml`'s `mcp:` is the lowest layer; a file `Troupe.Config` refuses leaves
  # it out and says so beside the other warnings, since a panel is not the place a
  # config error stops everything. The workspace's layer reads from outside the
  # repository only once the user's file trusts the workspace, as a session here would
  # read it (Decision 830).
  defp resolve(workspace) do
    trusted? = is_binary(workspace) and Troupe.Config.trusted?(workspace)

    case Troupe.Config.resolve(workspace) do
      {:ok, config, _layers} ->
        Local.resolve(workspace, base: config.mcp, trusted: trusted?)

      {:error, error} ->
        {servers, warnings} = Local.resolve(workspace, trusted: trusted?)
        {servers, [Exception.message(error) | warnings]}
    end
  end

  defp server_json(server, workspace, live) do
    config = server.config

    %{
      "name" => server.name,
      "layer" => to_string(server.layer),
      "source" => Paths.display(server.source),
      "transport" => if(is_binary(config[:url]), do: "http", else: "stdio"),
      "command" => config[:command],
      "args" => config[:args] || [],
      "url" => config[:url],
      "cd" => config[:cd],
      "env" => config |> Map.get(:env, %{}) |> Map.keys() |> Enum.sort(),
      "headers" => config |> Map.get(:headers, %{}) |> Map.keys() |> Enum.sort(),
      "permission" => to_string(config[:permission] || :ask),
      "disabled" => server.disabled?,
      "refused" => config[:refused],
      "trust" => trust_of(server, workspace),
      "notes" => notes_of(server, workspace),
      "oauth" => oauth_json(config),
      "auth" => auth_json(server)
    }
    |> Map.merge(status_json(live))
  end

  # A server the session runs that no file names any more: its live state, and the
  # layer it started from.
  defp live_json(name, status) do
    %{
      "name" => name,
      "layer" => to_string(status[:layer] || :session),
      "source" => status[:source] && Paths.display(status[:source])
    }
    |> Map.merge(status_json(status))
  end

  defp status_json(nil), do: %{"state" => nil, "tools" => [], "error" => nil}

  defp status_json(status),
    do: %{"state" => to_string(status.state), "tools" => status.tools, "error" => status.error}

  defp trust_of(%{layer: :workspace} = server, workspace) when is_binary(workspace) do
    trusted? = Troupe.Config.trusted?(workspace) or Trust.approved?(nil, workspace, server)
    if trusted?, do: "trusted", else: "pending"
  end

  defp trust_of(_server, _workspace), do: nil

  # What of a server waits for the workspace to be trusted, in `agents.list`'s shape
  # (Decision 825): a workspace's `permission: auto`, which a session holds until then
  # (Decision 830), whatever its start's answer was.
  defp notes_of(server, workspace) when is_binary(workspace) do
    if Local.waits_for_trust?(server) and not Troupe.Config.trusted?(workspace),
      do: [%{"key" => "permission", "reason" => Local.held_reason([server.name], workspace)}],
      else: []
  end

  defp notes_of(_server, _workspace), do: []

  defp entry_json(entry), do: entry |> names_of("env") |> names_of("headers")

  # A server's environment and headers by name, never their values (Decision 820).
  defp names_of(entry, key) do
    case entry[key] do
      %{} = values when values != %{} -> Map.put(entry, key, values |> Map.keys() |> Enum.sort())
      _none -> Map.delete(entry, key)
    end
  end

  # -- skills --------------------------------------------------------------------

  # What is offered, and beside it every skill the layers hold and do not offer, with why
  # (Decision 822): one a nearer layer's name hid, or one outside its edge, never read.
  defp list_skills(params) do
    with {:ok, workspace} <- workspace_of(params) do
      %{skills: skills, skipped: skipped} = Skills.Local.resolve(workspace)

      {:ok,
       %{
         "skills" => Enum.map(skills, &Map.put(skill_json(&1), "description", &1.description)),
         "skipped" =>
           Enum.map(
             skipped,
             &Map.merge(skill_json(&1), %{"status" => to_string(&1.status), "reason" => &1.reason})
           )
       }}
    end
  end

  defp skill_json(skill) do
    %{
      "name" => skill.name,
      "layer" => to_string(skill.layer),
      "source" => Paths.display(skill.source),
      "dir" => Paths.display(skill.dir),
      "linked" => skill.linked?
    }
  end

  defp add_skill(params) do
    with {:ok, scope} <- scope_of(params),
         {:ok, workspace} <- workspace_of(params),
         {:ok, from} <- fetch(params, "from") do
      case Skills.Local.add(scope, workspace, from, params["link"] == true) do
        {:ok, result} ->
          {:ok,
           %{
             "path" => Paths.display(result.path),
             "from" => result.from,
             "added" => result.added,
             "skipped" => Enum.map(result.skipped, &%{"name" => &1.name, "reason" => &1.reason}),
             "linked" => result.linked
           }}

        {:error, reason} ->
          invalid(reason)
      end
    end
  end

  defp remove_skill(params) do
    with {:ok, scope} <- scope_of(params),
         {:ok, workspace} <- workspace_of(params),
         {:ok, what} <- what_to_remove(params) do
      case Skills.Local.remove(scope, workspace, what) do
        {:ok, result} ->
          {:ok, %{"path" => Paths.display(result.path), "removed" => result.removed}}

        {:error, reason} ->
          invalid(reason)
      end
    end
  end

  # -- params ----------------------------------------------------------------------

  defp scope_of(params) do
    case Map.get(params, "scope", "user") do
      "user" -> {:ok, :user}
      "workspace" -> {:ok, :workspace}
      other -> invalid("scope must be user or workspace, not #{inspect(other)}")
    end
  end

  # A workspace named outright, or the one a named session runs in.
  defp workspace_of(%{"workspace" => workspace}) when is_binary(workspace) and workspace != "",
    do: {:ok, Path.expand(workspace)}

  defp workspace_of(%{"session_id" => session_id})
       when is_binary(session_id) and session_id != "" do
    case Troupe.get_session(session_id) do
      %{workspace: workspace} when is_binary(workspace) -> {:ok, workspace}
      _ -> {:error, Error.new(:not_found, %{kind: "session", session_id: session_id})}
    end
  end

  defp workspace_of(_params), do: {:ok, nil}

  defp what_to_remove(%{"name" => name}) when is_binary(name) and name != "",
    do: {:ok, %{name: name}}

  defp what_to_remove(%{"include" => path}) when is_binary(path) and path != "",
    do: {:ok, %{include: path}}

  defp what_to_remove(_params), do: invalid("give a name to remove, or a linked file as include")

  defp fetch(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new(:invalid_params, %{field: key, reason: "required"})}
    end
  end

  defp invalid(reason), do: {:error, Error.new(:invalid_params, %{reason: reason})}
end
