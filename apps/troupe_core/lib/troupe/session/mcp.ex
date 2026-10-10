defmodule Troupe.Session.MCP do
  @moduledoc """
  The MCP servers a local session has of its own (Decisions 654 and 700).

  Three layers, lowest first: `mcp:` in `config.yaml` (Decision 654, the user's and a
  trusted workspace's), the user's `mcp.json`, and the workspace's `.troupe/mcp.json`
  (`Troupe.MCP.Local`). A pod's servers come from its bundle and are discovered
  pod-wide; a pod session reads none of these layers, since a checkout's file must never
  start a command on somebody else's machine.

      mcp:
        filesystem:
          command: npx
          args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
        wiki:
          url: https://wiki.example/mcp

  A `command` server speaks over its standard streams and lives as long as the session
  (`Troupe.MCP.Stdio`); a `url` server is the same HTTP client the pod uses, discovered
  once when the session starts, and the MCP session it issues lasts as long as the
  session (Decision 746). Both kinds' tools are `mcp.<server>.<tool>` and go through the
  same gate as everything else; `permission: auto` on a server lowers its tools from the
  default `ask`.

  **The workspace's servers are asked about first.** A `.troupe/mcp.json` arrives with
  a clone, so its servers start only once somebody attached has said so, through the
  session's question path (`Troupe.Session.Questions`, the way an `ask_user` is
  answered) — `allow` remembers the answer for this workspace (`Troupe.MCP.Trust`),
  `once` runs them this session, `deny` runs nothing. A workspace on the user file's
  `trusted_workspaces` is not asked, and neither is anybody where nobody is attached:
  an unattended session leaves them waiting. `managed_mcp_servers_only` from a plane
  starts nothing local at all, and each server says so in its status.

  **The answer grants starting them, and no more.** A workspace's server set to
  `permission: auto` runs its tools unasked only once the workspace is trusted, as its
  agents' `auto` does (Decisions 825 and 830): until then each call asks, and the
  question says so. A pod trusts no workspace, and reads none of these layers anyway.

  A server is `reload`ed by name — after an edit to its file, or to bring one back —
  which reads the layers again for that name, stops what ran under it and starts what
  they say now. Supervised with the stdio servers as linked children, so a server that
  dies takes this holder with it and the supervisor brings the set back together.
  """

  use GenServer

  alias Troupe.MCP.{Client, Local, OAuth, Server, Sessions, Stdio, Tool, Trust}
  alias Troupe.Session.Questions

  require Logger

  defstruct [
    :session_id,
    :workspace,
    :state_dir,
    # The table the URL servers' MCP sessions are kept in (Decision 746), the session's.
    :sessions,
    local?: true,
    trusted?: false,
    managed_only?: false,
    # Every server the layers name, by name: its record (`Troupe.MCP.Local.server/0`)
    # and how it stands here — `:stdio` running, `:http` discovered, `:pending` an
    # answer, `:denied` one, `:disabled`, or `:refused` with why.
    servers: %{},
    # The question out for the workspace's servers, when one is: its id and the names.
    asking: nil
  ]

  @wait_for_state 20_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Troupe.Registry.session_mcp(session_id))
  end

  @doc "Every local server's tools, for `Troupe.Tools.all/1`."
  @spec tools(String.t()) :: [Troupe.Tool.handle()]
  def tools(session_id), do: call(session_id, :tools, [])

  @doc """
  What a client shows about the servers: name, layer, source, state, tool names, error.
  `state` is `connecting`, `ready`, `error`, `stopped`, `pending` (the workspace's
  question is unanswered), `disabled` or `sign_in` (the server wants the person signed
  in, and they have not, or their sign-in has run out: Decision 741).
  """
  @spec status(String.t()) :: [map()]
  def status(session_id), do: call(session_id, :status, [])

  @doc """
  Read the layers again for one server and start what they say now, stopping whatever
  ran under that name: a server whose file changed, one that died, or one added since
  the session began. Answers its status once it is ready or has failed, or `pending`
  when the workspace's question went out again.
  """
  @spec reload(String.t(), String.t()) :: {:ok, map()} | {:error, :unknown_server | :no_session}
  def reload(session_id, name) do
    case GenServer.call(
           Troupe.Registry.session_mcp(session_id),
           {:reload, name},
           @wait_for_state + 5_000
         ) do
      :ok -> {:ok, await_state(session_id, name, @wait_for_state)}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  Tell every local session that a person has signed in to a server (Decision 741), so a
  session that was waiting for it asks for its tools now.
  """
  @spec signed_in(OAuth.binding()) :: :ok
  def signed_in(binding) do
    state_dir = Troupe.Paths.state_dir(binding.state_dir)

    Enum.each(
      Troupe.Registry.session_mcp_holders(),
      &send(&1, {:oauth_signed_in, state_dir, binding.key})
    )
  end

  @doc """
  Try a server outside any session: start it, wait until it is ready or has failed,
  stop it, and say what it offered. What `mcp.check` answers before a server is kept.
  """
  @spec probe(Local.server(), Path.t() | nil) :: map()
  def probe(%{name: name, config: config} = server, workspace) do
    status =
      cond do
        is_binary(config[:refused]) ->
          %{name: name, state: :error, tools: [], error: config.refused}

        is_binary(config[:command]) ->
          Stdio.probe(name, config, workspace, @wait_for_state)

        is_binary(config[:url]) ->
          name |> http_server(config, nil) |> http_status()

        true ->
          %{name: name, state: :error, tools: [], error: "has neither a command nor a url"}
      end

    Map.merge(status, %{layer: server.layer, source: server.source})
  end

  @doc """
  A URL server's tools outside any session, for a person's client that offers them to a
  session somewhere else (`mcp.tools`, Decision 748): asked for as a session asks, with
  the person's sign-in when the server wants one, and answered as `probe/2` answers, with
  the tools themselves beside the status.
  """
  @spec discover(Local.server()) :: {map(), [Tool.t()]}
  def discover(%{name: name, config: %{url: url} = config} = server) when is_binary(url) do
    http = http_server(name, config, nil)
    {Map.merge(http_status(http), %{layer: server.layer, source: server.source}), http.tools}
  end

  @doc "The server a session would call for a URL server, sign-in and all: what `mcp.call` calls (Decision 748)."
  @spec server(Local.server()) :: Server.t()
  def server(%{name: name, config: %{url: url} = config}) when is_binary(url),
    do: server_of(name, config, nil)

  defp call(session_id, message, default) do
    GenServer.call(Troupe.Registry.session_mcp(session_id), message, 15_000)
  catch
    :exit, _ -> default
  end

  # A stdio server takes a moment to answer `initialize`; `reload` waits for it so a
  # client's one call sees the outcome rather than `connecting`.
  defp await_state(session_id, name, waited) do
    entry =
      Enum.find(status(session_id), &(&1.name == name)) ||
        %{name: name, state: :stopped, tools: [], error: nil}

    if entry.state == :connecting and waited > 0 do
      Process.sleep(200)
      await_state(session_id, name, waited - 200)
    else
      entry
    end
  end

  ## Server

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    workspace = Keyword.fetch!(opts, :workspace)
    Process.set_label("troupe session mcp #{session_id}")
    local? = Keyword.get(opts, :local, true)

    state = %__MODULE__{
      session_id: session_id,
      workspace: workspace,
      state_dir: Keyword.get(opts, :state_dir),
      sessions: opts |> Keyword.get(:sessions) |> Sessions.table(),
      local?: local?,
      # A pod trusts no workspace (Decision 825), whatever the list says.
      trusted?: local? and Keyword.get(opts, :trusted, false),
      managed_only?: Keyword.get(opts, :managed_only, false)
    }

    {:ok, state, {:continue, {:start, Keyword.get(opts, :servers, %{})}}}
  end

  @impl GenServer
  def handle_continue({:start, base}, state) do
    {records, warnings} = resolve(state, base)
    Enum.each(warnings, &Logger.warning("troupe: mcp: " <> &1))

    state = Enum.reduce(records, state, fn record, acc -> place(acc, record) end)
    {:noreply, ask_for_workspace(state)}
  end

  # The layers as they stand: the three of them for a local session, `config.yaml`'s
  # alone for a pod's.
  defp resolve(%{local?: false}, base),
    do: {Enum.map(base, fn {name, config} -> base_record(name, config) end), []}

  # The workspace's layer reads from outside the repository only once the workspace is
  # trusted (Decision 830), as the session judged it when it started.
  defp resolve(state, base),
    do: Local.resolve(state.workspace, base: base, trusted: state.trusted?)

  defp base_record(name, config) do
    %{
      name: name,
      layer: :config,
      source: "config.yaml",
      config: config,
      disabled?: false,
      fingerprint: Local.fingerprint(config)
    }
  end

  # Where a server stands, before anything runs: refused outright, disabled, waiting
  # for the workspace's answer, or started.
  defp place(state, record) do
    entry =
      cond do
        state.managed_only? ->
          refused(
            record,
            "managed_mcp_servers_only: this platform allows only its profiles' MCP servers"
          )

        is_binary(record.config[:refused]) ->
          refused(record, record.config.refused)

        record.disabled? ->
          %{record: record, kind: :disabled}

        record.layer == :workspace and not approved?(state, record) ->
          %{record: record, kind: :pending}

        true ->
          start(state, record)
      end

    %{state | servers: Map.put(state.servers, record.name, entry)}
  end

  # A server whose config reads a `{env:VAR}` that is not set is never started: it would
  # run with a credential missing, or be told the placeholder. `/mcp` says why.
  defp refused(record, why), do: %{record: record, kind: :refused, error: why}

  defp approved?(%{trusted?: true}, _record), do: true
  defp approved?(state, record), do: Trust.approved?(state.state_dir, state.workspace, record)

  defp start(state, %{name: name} = record) do
    config = permitted(state, record)

    cond do
      is_binary(config[:command]) ->
        case Stdio.start_link(
               session_id: state.session_id,
               name: name,
               config: config,
               cwd: state.workspace
             ) do
          {:ok, pid} ->
            %{record: record, kind: :stdio, pid: pid}

          {:error, reason} ->
            Logger.warning("troupe: MCP server #{name}: #{inspect(reason)}")
            %{record: record, kind: :refused, error: "could not start: #{inspect(reason)}"}
        end

      is_binary(config[:url]) ->
        %{
          record: record,
          kind: :http,
          http: http_server(name, config, state.state_dir, state.sessions)
        }

      true ->
        Logger.warning("troupe: MCP server #{name} has neither command nor url; ignored")
        %{record: record, kind: :refused, error: "has neither a command nor a url"}
    end
  end

  # The config a server starts with: a workspace's `auto` is held until the workspace is
  # trusted (Decision 830), here where its tools are made, so a stdio server's and a URL
  # server's alike, and one started again by a reload or a sign-in, ask until then.
  defp permitted(state, %{config: config} = record) do
    if not state.trusted? and Local.waits_for_trust?(record),
      do: %{config | permission: :ask},
      else: config
  end

  # -- the workspace's question ----------------------------------------------------

  # One question for every workspace server still waiting, asked from a task so this
  # holder keeps answering. The id is a hash of what would run, so a session that
  # comes back asks under the same id and finds an answer given while it was away.
  defp ask_for_workspace(%{asking: nil} = state) do
    case pending_names(state) do
      [] ->
        state

      names ->
        records = Enum.map(names, &state.servers[&1].record)
        call_id = "mcp-trust-" <> question_id(records)
        parent = self()
        session_id = state.session_id
        question = question(call_id, records, state.workspace)

        {:ok, _pid} =
          Task.start_link(fn ->
            send(parent, {:trust_answer, call_id, names, Questions.ask(session_id, question)})
          end)

        %{state | asking: %{call_id: call_id, names: names}}
    end
  end

  defp ask_for_workspace(state), do: state

  defp pending_names(state) do
    state.servers
    |> Enum.filter(fn {_name, entry} -> entry.kind == :pending end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp question_id(records) do
    records
    |> Enum.map(&[&1.name, &1.fingerprint])
    |> Enum.sort()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  # The answer grants starting the servers and nothing else (Decision 830), so the
  # question says that, and for a server set to `auto` that its tools still ask until the
  # workspace is trusted: only an untrusted workspace is asked at all.
  defp question(call_id, records, workspace) do
    listed = Enum.map_join(records, "; ", &describe/1)

    held =
      case for(record <- records, Local.waits_for_trust?(record), do: record.name) do
        [] -> ""
        names -> " " <> Local.held_reason(names, workspace) <> "."
      end

    %{
      call_id: call_id,
      agent_path: Troupe.Session.root_path(),
      question:
        "This workspace's .troupe/mcp.json names MCP servers to start on this machine: " <>
          "#{listed}.#{held} Start them?",
      options: [
        %{label: "deny", description: "start none of them; asked again next session"},
        %{label: "once", description: "start them for this session only"},
        %{label: "allow", description: "start them, and remember it for this workspace"}
      ],
      multiple: false
    }
  end

  defp describe(%{name: name, config: %{command: command} = config}) when is_binary(command),
    do: "#{name} (#{Enum.join([command | config.args], " ")})"

  # A workspace's server that sends headers sends what they read to its URL, the
  # person's own variables among them (Decision 820): the question names them.
  defp describe(%{name: name, config: %{url: url, headers: %{} = headers}})
       when is_binary(url) and headers != %{} do
    "#{name} (#{url}, sending the headers #{headers |> Map.keys() |> Enum.sort() |> Enum.join(", ")})"
  end

  defp describe(%{name: name, config: %{url: url}}) when is_binary(url), do: "#{name} (#{url})"
  defp describe(%{name: name}), do: name

  @impl GenServer
  def handle_info({:trust_answer, call_id, names, answer}, %{asking: %{call_id: call_id}} = state) do
    decision = decision(answer)
    Logger.info("troupe: mcp: the workspace's servers #{Enum.join(names, ", ")}: #{decision}")

    if decision == :allow do
      records = Enum.map(names, &state.servers[&1].record)

      case Trust.approve(state.state_dir, state.workspace, records) do
        :ok -> :ok
        {:error, why} -> Logger.warning("troupe: mcp: " <> why)
      end
    end

    # A `deny` is kept as such for the rest of the session — asked again by a `reload`
    # or the next session, never by this holder looping back to the question.
    state =
      Enum.reduce(names, %{state | asking: nil}, fn name, acc ->
        case Map.fetch(acc.servers, name) do
          {:ok, %{kind: :pending, record: record}} when decision in [:allow, :once] ->
            %{acc | servers: Map.put(acc.servers, name, start(acc, record))}

          {:ok, %{kind: :pending, record: record}} ->
            %{acc | servers: Map.put(acc.servers, name, %{record: record, kind: :denied})}

          _ ->
            acc
        end
      end)

    # Asked again for whatever was added while the question was out.
    {:noreply, ask_for_workspace(state)}
  end

  # A sign-in finished (Decision 741): every server of this session that it serves is
  # asked for its tools again, which is how one that waited for it becomes `ready`.
  def handle_info({:oauth_signed_in, state_dir, key}, state) do
    servers =
      Map.new(state.servers, fn
        {name, %{kind: :http, http: %{server: %Server{oauth: %{key: ^key} = binding}}} = entry} ->
          if Troupe.Paths.state_dir(binding.state_dir) == state_dir,
            do: {name, start(state, entry.record)},
            else: {name, entry}

        other ->
          other
      end)

    {:noreply, %{state | servers: servers}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A crash report prints the state, and a server's environment and headers can hold a
  # credential (Decision 820): it prints their names.
  @impl GenServer
  def format_status(status), do: Map.replace_lazy(status, :state, &redacted/1)

  defp redacted(%__MODULE__{servers: servers} = state) do
    %{state | servers: Map.new(servers, fn {name, entry} -> {name, redacted_entry(entry)} end)}
  end

  defp redacted(state), do: state

  defp redacted_entry(%{record: %{config: config} = record} = entry) do
    config = config |> names_only(:env) |> names_only(:headers)
    %{entry | record: %{record | config: config}}
  end

  defp redacted_entry(entry), do: entry

  defp names_only(config, key) do
    case config do
      %{^key => %{} = values} -> Map.put(config, key, values |> Map.keys() |> Enum.sort())
      _other -> config
    end
  end

  defp decision({:ok, text}) when is_binary(text) do
    case text |> String.trim() |> String.downcase() do
      allow when allow in ["allow", "always", "yes", "y", "a"] -> :allow
      once when once in ["once", "this session", "session", "o"] -> :once
      _other -> :deny
    end
  end

  defp decision(_unattended_or_odd), do: :deny

  # -- reads -----------------------------------------------------------------------

  @impl GenServer
  def handle_call(:tools, _from, state) do
    tools =
      Enum.flat_map(state.servers, fn
        {name, %{kind: :stdio}} -> Stdio.tools(state.session_id, name)
        {_name, %{kind: :http, http: http}} -> http.tools
        _other -> []
      end)

    {:reply, tools, state}
  end

  def handle_call(:status, _from, state) do
    listed =
      state.servers
      |> Enum.map(fn {name, entry} -> entry_status(state, name, entry) end)
      |> Enum.sort_by(& &1.name)

    {:reply, listed, state}
  end

  def handle_call({:reload, name}, _from, state) do
    {records, warnings} = resolve(state, base_of(state))
    Enum.each(warnings, &Logger.warning("troupe: mcp: " <> &1))

    case Enum.find(records, &(&1.name == name)) do
      nil ->
        {:reply, {:error, :unknown_server}, stop_server(state, name)}

      record ->
        state = state |> stop_server(name) |> place(record)
        {:reply, :ok, ask_for_workspace(state)}
    end
  end

  # `config.yaml`'s entries as the session started with them: a reload reads the
  # `mcp.json` layers again, and the config a session runs under does not move.
  defp base_of(state) do
    state.servers
    |> Enum.filter(fn {_name, %{record: record}} -> record.layer == :config end)
    |> Map.new(fn {name, %{record: record}} -> {name, record.config} end)
  end

  defp stop_server(state, name) do
    case Map.fetch(state.servers, name) do
      {:ok, %{kind: :stdio, pid: pid}} ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
        %{state | servers: Map.delete(state.servers, name)}

      {:ok, _entry} ->
        %{state | servers: Map.delete(state.servers, name)}

      :error ->
        state
    end
  catch
    :exit, _ -> %{state | servers: Map.delete(state.servers, name)}
  end

  defp entry_status(state, name, %{record: record} = entry) do
    status =
      case entry do
        %{kind: :stdio} ->
          Stdio.status(state.session_id, name)

        %{kind: :http, http: http} ->
          http_status(http)

        %{kind: :pending} ->
          %{
            name: name,
            state: :pending,
            tools: [],
            error: "waiting for approval to run this workspace's servers"
          }

        %{kind: :denied} ->
          %{
            name: name,
            state: :stopped,
            tools: [],
            error: "not approved for this workspace; asked again next session"
          }

        %{kind: :disabled} ->
          %{name: name, state: :disabled, tools: [], error: nil}

        %{kind: :refused, error: why} ->
          %{name: name, state: :error, tools: [], error: why}
      end

    Map.merge(status, %{layer: record.layer, source: record.source})
  end

  # A server that wants the person signed in is `sign_in` until they have, and again
  # once their sign-in has run out, whichever session found that out.
  defp http_status(%{server: server, tools: tools, error: error} = http) do
    {state, error} =
      cond do
        Map.get(http, :sign_in, false) -> {:sign_in, error}
        error -> {:error, error}
        run_out?(server) -> {:sign_in, "the sign-in to #{server.name} has run out; sign in again"}
        true -> {:ready, nil}
      end

    %{name: server.name, state: state, tools: Enum.map(tools, & &1.remote_name), error: error}
  end

  defp run_out?(%Server{oauth: %{} = binding}),
    do: OAuth.status(binding).state in [:expired, :signed_out]

  defp run_out?(_server), do: false

  # Discovered once, here: a URL server's tools are a property of the server, and a
  # session asking on every prompt would put the server's latency on every turn. One that
  # wants the person signed in (Decision 741) is asked with their token, and waits for
  # their sign-in when there is none: `signed_in/1` brings it back. The MCP session the
  # server issues is the local session's, kept in its table (Decision 746); with none,
  # outside a session, each request opens and ends its own.
  defp http_server(name, config, state_dir, sessions \\ nil) do
    server = name |> server_of(config, state_dir) |> Map.put(:sessions, sessions)

    case OAuth.authorized(server, &Client.list_tools/1) do
      {:ok, listed} ->
        %{server: server, tools: Enum.map(listed, &Tool.new(server, &1)), error: nil}

      {:error, :sign_in_required} ->
        %{
          server: server,
          tools: [],
          sign_in: true,
          error:
            "sign in to #{name}: /mcp sign-in #{name}, or Sign in on the desktop app's Servers and skills"
        }

      {:error, {:unauthorized, _challenge}} ->
        %{
          server: server,
          tools: [],
          error:
            "answered 401: it wants a sign-in; give its entry oauth.client_id, " <>
              "a client registered with the server's authorization server"
        }

      {:error, reason} when is_binary(reason) ->
        %{server: server, tools: [], error: reason}

      {:error, reason} ->
        %{server: server, tools: [], error: "unreachable: #{inspect(reason)}"}
    end
  end

  defp server_of(name, config, state_dir) do
    Server.from_config(%{
      "name" => name,
      "url" => config[:url],
      "headers" => config[:headers],
      "permission" => config[:permission] || :ask,
      "timeout_ms" => config[:timeout_ms] || 30_000
    })
    |> with_oauth(config[:oauth], state_dir)
  end

  defp with_oauth(server, %{client_id: _} = oauth, state_dir),
    do: %{server | oauth: OAuth.binding(server.name, server.url, oauth, state_dir)}

  defp with_oauth(server, _none, _state_dir), do: server
end
