defmodule Troupe.Gateway.LocalSources do
  @moduledoc """
  `mcp.list`, `mcp.add`, `mcp.remove`, `mcp.check` and `skills.list`, `skills.add`,
  `skills.remove`, `skills.discover`: the person's own MCP servers and skills, over the wire
  (Decision 700). `mcp.sign_in` and `mcp.sign_out`: their sign-in to a server that wants
  them rather than a machine (Decision 741). `mcp.tools` and `mcp.call`: one of their
  servers listed and called outside any session, with their sign-in, for a client that
  offers its tools to a session on a pod (Decision 748). `mcp.secret`: a value one of
  their servers needs, kept in the operating system's credential store and written into
  the entry as a `{secret:…}` reference (`Troupe.MCP.Secrets`).

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

  alias Troupe.MCP.{Import, Local, OAuth, Secrets, Tool, Trust}
  alias Troupe.Paths
  alias Troupe.Protocol.Error
  alias Troupe.Session.MCP, as: LocalMCP
  alias Troupe.Skills

  @type outcome :: {:ok, map()} | {:error, Error.t()}

  @doc "Dispatch one of these methods, with the daemon already known to be the server."
  @spec call(String.t(), map()) :: outcome()
  def call("mcp.list", params), do: list_servers(params)
  def call("mcp.add", params), do: add_server(params)
  def call("mcp.remove", params), do: remove_server(params)
  def call("mcp.secret", params), do: put_secret(params)
  def call("mcp.check", params), do: check_server(params)
  def call("mcp.sign_in", params), do: sign_in(params)
  def call("mcp.sign_out", params), do: sign_out(params)
  def call("mcp.tools", params), do: server_tools(params)
  def call("mcp.call", params), do: call_tool(params)
  def call("skills.list", params), do: list_skills(params)
  def call("skills.discover", params), do: discover_skills(params)
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

  # A server taken out of its file takes the secrets the store kept for it along: they are
  # its, under its name, and nothing else reads them.
  defp remove_server(params) do
    with {:ok, scope} <- scope_of(params),
         {:ok, workspace} <- workspace_of(params),
         {:ok, what} <- what_to_remove(params) do
      kept = kept_secrets(scope, workspace, what)

      case Local.remove(scope, workspace, what) do
        {:ok, result} ->
          Enum.each(kept, &Secrets.delete/1)
          {:ok, %{"path" => Paths.display(result.path), "removed" => result.removed}}

        {:error, reason} ->
          invalid(reason)
      end
    end
  end

  defp kept_secrets(scope, workspace, %{name: name}) do
    {servers, _warnings} = resolve(workspace)

    case Enum.find(servers, &(&1.name == name and &1.layer == scope)) do
      %{config: %{secrets: keys}} ->
        Enum.map(keys, &Secrets.ref(name, &1, secret_home(scope, workspace)))

      _none ->
        []
    end
  end

  defp kept_secrets(_scope, _workspace, _what), do: []

  defp secret_home(:workspace, workspace), do: workspace
  defp secret_home(:user, _workspace), do: nil

  # One value a server needs, kept in the store and named in the entry: `value` keeps it
  # (replacing one there), `null` forgets it and takes the key out. `field` is `env`, a
  # variable, or `headers`. The entry is written as `mcp.add` writes one, merged onto the
  # layer's, so a server from a lower layer gets the key over it in this one. A store this
  # machine does not have is said, and nothing is written.
  defp put_secret(params) do
    with {:ok, scope} <- scope_of(params),
         {:ok, workspace} <- workspace_of(params),
         {:ok, name} <- fetch(params, "name"),
         {:ok, key} <- fetch(params, "key"),
         {:ok, field} <- secret_field(params),
         :ok <- workspace_for(scope, workspace) do
      ref = Secrets.ref(name, key, secret_home(scope, workspace))

      case Map.get(params, "value") do
        value when is_binary(value) and value != "" ->
          keep_secret(scope, workspace, name, field, key, ref, value)

        nil ->
          forget_secret(scope, workspace, name, field, key, ref)

        _other ->
          invalid("value is the secret to keep, or null to forget it")
      end
    end
  end

  defp keep_secret(scope, workspace, name, field, key, ref, value) do
    with :ok <- stored(Secrets.put(ref, value)),
         {:ok, result} <-
           written(
             Local.add(scope, workspace, name, %{field => %{key => Secrets.reference(ref)}})
           ) do
      {:ok, Map.merge(result, %{"key" => key, "field" => field, "state" => "set"})}
    end
  end

  defp forget_secret(scope, workspace, name, field, key, ref) do
    with {:ok, result} <- written(Local.add(scope, workspace, name, %{field => %{key => nil}})) do
      _ = Secrets.delete(ref)
      {:ok, Map.merge(result, %{"key" => key, "field" => field, "state" => "removed"})}
    end
  end

  defp stored(:ok), do: :ok

  defp stored({:error, :unavailable}),
    do:
      {:error,
       Error.new(:unavailable, %{
         reason:
           "this computer has no keychain Troupe can use (on Linux, the Secret Service and " <>
             "secret-tool); write {env:NAME} in the entry instead"
       })}

  defp stored({:error, why}),
    do: {:error, Error.new(:unavailable, %{reason: "the keychain refused it: #{inspect(why)}"})}

  defp secret_field(params) do
    case Map.get(params, "field", "env") do
      field when field in ["env", "headers"] -> {:ok, field}
      other -> invalid("field is env or headers, not #{inspect(other)}")
    end
  end

  defp workspace_for(:workspace, nil), do: invalid("the workspace scope needs a workspace")
  defp workspace_for(_scope, _workspace), do: :ok

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
             "expires_at" => started.expires_at,
             "scopes" => started.scopes
           }}

        {:error, why} ->
          invalid(why)
      end
    end
  end

  # Forgotten on this machine, and the provider asked to revoke the refresh token
  # (Decision 872): `revocation` says whether it was told. `all` is every server signed in
  # to here, by whatever name and in whatever workspace, for `troupe logout`.
  defp sign_out(%{"all" => true}) do
    case OAuth.sign_out_all(nil) do
      {:ok, outcomes} ->
        {:ok,
         %{
           "servers" =>
             Enum.map(outcomes, &%{"server" => &1.server, "revocation" => revocation_json(&1)})
         }}

      {:error, why} ->
        invalid(why)
    end
  end

  defp sign_out(params) do
    with {:ok, server} <- signable(params),
         {:ok, revocation} <- server |> sign_in_of() |> OAuth.sign_out() do
      {:ok,
       %{
         "server" => server.name,
         "auth" => auth_json(server),
         "revocation" => revocation_json(revocation)
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, why} -> invalid(why)
    end
  end

  defp revocation_json(%{state: state, reason: reason}),
    do: %{"state" => to_string(state), "reason" => reason}

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
    do:
      invalid(
        "#{name} takes no sign-in: give its entry an oauth to sign in to it, {} where its " <>
          "authorization server registers clients, or with oauth.client_id"
      )

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

  # `files` where the server's entry says the tool is where the organisation keeps files,
  # for the client to say so again when it offers the tool. `title`, `summary` (the
  # server's own description, without the line Troupe adds for the model) and
  # `read_only` are what the server says of the tool, for a person to read.
  defp tool_json(tool) do
    json = %{
      "name" => tool.remote_name,
      "description" => tool.description,
      "schema" => tool.schema,
      "title" => tool.title,
      "summary" => tool.summary,
      "read_only" => tool.read_only
    }

    if tool.files, do: Map.put(json, "files", true), else: json
  end

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
  # why the last attempt failed, and the scope the server wanted on top of it.
  defp auth_json(%{config: %{oauth: %{}, url: url}} = server) when is_binary(url) do
    status = server |> sign_in_of() |> OAuth.status()

    %{
      "state" => to_string(status.state),
      "account" => status.account,
      "error" => status.error,
      "step_up" => status.step_up
    }
  end

  defp auth_json(_server), do: nil

  # Everything the entry says about the sign-in, so a form that edits the entry starts
  # from what it has; `resource` only when it is off, as the file says it.
  defp oauth_json(%{oauth: %{} = oauth}) do
    %{
      "client_id" => oauth.client_id,
      "scopes" => oauth.scopes,
      "issuer" => oauth.issuer,
      "redirect_uri" => Map.get(oauth, :redirect_uri),
      "resource" => if(Map.get(oauth, :resource) == false, do: false)
    }
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
      # From a file the layer links rather than the layer's own: read there each time.
      "linked" => linked?(server, workspace),
      "transport" => if(is_binary(config[:url]), do: "http", else: "stdio"),
      "command" => config[:command],
      "args" => config[:args] || [],
      "url" => config[:url],
      "cd" => config[:cd],
      "env" => config |> Map.get(:env, %{}) |> Map.keys() |> Enum.sort(),
      "headers" => config |> Map.get(:headers, %{}) |> Map.keys() |> Enum.sort(),
      # Which of those the store keeps, and which want a value they do not have.
      "secrets" => config[:secrets] || [],
      "missing" => config[:missing] || [],
      "permission" => to_string(config[:permission] || :ask),
      "timeout_ms" => config[:timeout_ms],
      "stores" => if(config[:stores] == :files, do: "files"),
      "files" => config[:files],
      "disabled" => server.disabled?,
      "refused" => config[:refused],
      "trust" => trust_of(server, workspace),
      "notes" => notes_of(server, workspace),
      "oauth" => oauth_json(config),
      "auth" => auth_json(server)
    }
    |> Map.merge(status_json(live))
  end

  defp linked?(%{layer: :user, source: source}, _workspace) when is_binary(source),
    do: Path.expand(source) != Path.expand(Local.user_path())

  defp linked?(%{layer: :workspace, source: source}, workspace)
       when is_binary(source) and is_binary(workspace),
       do: Path.expand(source) != Path.expand(Local.workspace_path(workspace))

  defp linked?(_server, _workspace), do: false

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

  defp status_json(nil), do: %{"state" => nil, "tools" => [], "about" => [], "error" => nil}

  # `about`: each tool as its server describes it for a person (`Troupe.MCP.Tool.said/1`).
  defp status_json(status) do
    %{
      "state" => to_string(status.state),
      "tools" => status.tools,
      "about" => Enum.map(Map.get(status, :about, []), &about_json/1),
      "error" => status.error
    }
  end

  defp about_json(about),
    do: %{
      "name" => about.name,
      "title" => about.title,
      "summary" => about.summary,
      "read_only" => about.read_only
    }

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

  # What is offered, and beside it every skill the layers hold and do not offer, with why:
  # one a nearer layer's name hid, or one outside its edge, never read. A session here
  # trusts the workspace as the user's file says, so what its `skills.json` links from
  # outside the repository is listed as a session would read it. An offered skill missing a
  # program its `requires:` names is listed with `available: false` and what it lacks, as a
  # session here would offer it: kept, and marked as one that cannot run on this machine.
  defp list_skills(params) do
    with {:ok, workspace} <- workspace_of(params) do
      trusted? = workspace != nil and Troupe.Config.trusted?(workspace)
      %{skills: skills, skipped: skipped} = Skills.Local.resolve(workspace, trusted: trusted?)

      {:ok,
       %{
         "skills" => skills |> Skills.check() |> Enum.map(&offered_skill_json/1),
         "skipped" =>
           Enum.map(
             skipped,
             &Map.merge(skill_json(&1), %{"status" => to_string(&1.status), "reason" => &1.reason})
           )
       }}
    end
  end

  # The directories of skills other tools keep here, for a client to offer bringing in
  # with `skills.add`: read, never written.
  defp discover_skills(params) do
    with {:ok, workspace} <- workspace_of(params) do
      found = Skills.Local.discover(workspace)

      {:ok,
       %{
         "found" =>
           Enum.map(found, fn d ->
             %{
               "app" => d.app,
               "dir" => Paths.display(d.dir),
               "from" => d.dir,
               "scope" => to_string(d.scope),
               "state" => to_string(d.state),
               "skills" =>
                 Enum.map(d.skills, &%{"name" => &1.name, "description" => &1.description})
             }
           end)
       }}
    end
  end

  defp offered_skill_json(skill) do
    Map.merge(skill_json(skill), %{
      "description" => skill.description,
      "available" => skill.missing == [],
      "missing" => skill.missing
    })
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
