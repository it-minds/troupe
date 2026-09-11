defmodule Troupe.Session.ClientTools do
  @moduledoc """
  Tools that run on an attached client's machine, and who is allowed to run them.

  A harness can offer tools it hosts itself — a personal MCP connection, usually — to a
  session it is attached to. Three properties make that worth having rather than merely
  possible, and each is enforced here rather than asked for politely.

  **Consent is a round trip.** `challenge/3` issues a nonce bound to one connection, one
  subject and one set of tool names. `register/4` accepts nothing else. A client cannot
  set a boolean on its user's behalf, and a client cannot spend another client's
  challenge — which is the difference between a consent step and a consent field.

  **The registering connection owns the tool.** Each registration carries the pid that
  made it and an `invoke` function that can only reach that connection. A second client
  attached to the same session gets no path to it, and a registrant that disconnects
  takes its tools with it: this process monitors every registrant, and a `:DOWN` removes
  the registration and logs `tools_unregistered` before the agent's next lookup.

  **The taint is durable and visible.** `session_tainted` goes in the log and into the
  summary projection, because a tool executing outside the pod is something the other
  participants are entitled to know about — and to decide about — rather than something
  they discover in the transcript afterwards.

  Placed directly under `Session.Log` in the session tree, so a registration can be
  logged and an agent restart does not lose one. A crash here is worth restarting the
  agent for: registrations that are gone must not go on looking present.
  """

  use GenServer

  alias Troupe.Protocol.Event
  alias Troupe.Registry
  alias Troupe.Session.Log

  @prefix "client."

  # Long enough for a person to read a prompt and click; short enough that a challenge
  # left lying around is not a standing permission.
  @challenge_ttl_ms 5 * 60 * 1000

  defstruct [:session_id, tools: %{}, challenges: %{}, monitors: %{}]

  @typedoc """
  One registered tool, in the shape `Troupe.Tool` accepts as a value.

  `run/2` is supplied by whoever registered — the gateway, closing over the connection
  process — so nothing in core needs to know how a client is reached.
  """
  @type tool :: %{
          name: String.t(),
          description: String.t(),
          schema: map(),
          default_permission: :auto | :ask | :deny,
          run: (map(), Troupe.Tool.Ctx.t() -> Troupe.Tool.result()),
          connection: pid(),
          actor: Event.Actor.t() | nil
        }

  # -- client -----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Registry.client_tools(session_id))
  end

  @doc """
  Issue a consent challenge for one connection, subject and set of tools.

  The harness shows it to the person; the registration carries it back. Unspent
  challenges expire, and a connection's challenges die with it.
  """
  @spec challenge(String.t(), pid(), String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def challenge(session_id, connection, subject, names) do
    call(session_id, {:challenge, connection, subject, names})
  end

  @doc """
  Register tools, or refuse for want of consent.

  `specs` is a list of `%{name:, description:, schema:, run:}` — `run/2` is the function
  that reaches the registrant. Names are prefixed with `client.` so nothing a client
  offers can shadow a built-in.
  """
  @spec register(String.t(), pid(), map(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def register(session_id, connection, consent, opts) do
    call(session_id, {:register, connection, consent, opts})
  end

  @doc "Give tools up. `:all` for everything one connection registered."
  @spec unregister(String.t(), pid(), [String.t()] | :all, String.t()) :: {:ok, [String.t()]}
  def unregister(session_id, connection, names \\ :all, reason \\ "unregistered") do
    call(session_id, {:unregister, connection, names, reason}, {:ok, []})
  end

  @doc "Every registered tool, as `Troupe.Tool` handles."
  @spec list(String.t()) :: [tool()]
  def list(session_id), do: call(session_id, :list, [])

  @doc "Which connection owns a tool, if any."
  @spec owner(String.t(), String.t()) :: {:ok, pid()} | :error
  def owner(session_id, name), do: call(session_id, {:owner, name}, :error)

  @doc "What has tainted this session, oldest first."
  @spec taint(String.t()) :: [map()]
  def taint(session_id), do: call(session_id, :taint, [])

  @doc "The prefix every client-hosted tool's name carries."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # A session with no tree — dormant, or never started — has no client tools, and that
  # is an answer rather than a fault: the agent asks on every turn.
  defp call(session_id, message, default \\ {:error, :no_session}) do
    GenServer.call(Registry.client_tools(session_id), message)
  catch
    :exit, _reason -> default
  end

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Process.set_label("troupe client tools #{session_id}")
    {:ok, %__MODULE__{session_id: session_id}}
  end

  @impl GenServer
  def handle_call({:challenge, connection, subject, names}, _from, state) do
    nonce = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    entry = %{
      connection: connection,
      subject: subject,
      names: Enum.sort(names),
      expires_at: System.monotonic_time(:millisecond) + @challenge_ttl_ms
    }

    # The names as the person offered them, not as the model will call them: the prompt
    # is about their notes tool, and `client.` is our bookkeeping rather than theirs.
    challenge = %{"challenge" => nonce, "prompt" => prompt(names), "tools" => names}

    {:reply, {:ok, challenge},
     %{state | challenges: Map.put(state.challenges, nonce, entry)}}
  end

  def handle_call({:register, connection, consent, opts}, _from, state) do
    specs = Keyword.fetch!(opts, :specs)
    subject = Keyword.fetch!(opts, :subject)
    actor = Keyword.get(opts, :actor)
    names = Enum.map(specs, & &1.name)

    case spend(state, consent, connection, subject, names) do
      {:ok, spent, state} ->
        {registered, state} = do_register(state, connection, specs, actor, spent)
        {:reply, {:ok, registered}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unregister, connection, names, reason}, _from, state) do
    {gone, state} = drop(state, connection, names, reason)
    {:reply, {:ok, gone}, state}
  end

  def handle_call(:list, _from, state), do: {:reply, Map.values(state.tools), state}

  def handle_call({:owner, name}, _from, state) do
    case Map.fetch(state.tools, name) do
      {:ok, tool} -> {:reply, {:ok, tool.connection}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:taint, _from, state) do
    taint =
      state.session_id
      |> Log.replay()
      |> Enum.flat_map(fn
        %Event{type: "session_tainted", data: data} -> [data]
        _event -> []
      end)

    {:reply, taint, state}
  rescue
    _exception -> {:reply, [], state}
  end

  @impl GenServer
  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state) do
    {_gone, state} = drop(state, pid, :all, "disconnected")
    {:noreply, expire(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- consent ----------------------------------------------------------------

  # A challenge is spent once, by the connection it was issued to, for the subject it
  # was issued to, covering exactly the tools it named. Anything else is not consent.
  defp spend(state, consent, connection, subject, names) do
    nonce = consent["challenge"]
    state = expire(state)

    case Map.fetch(state.challenges, nonce) do
      {:ok, %{connection: ^connection, subject: ^subject, names: issued}} ->
        if issued == Enum.sort(names) do
          spent = %{
            "challenge" => nonce,
            "confirmed_by" => consent["confirmed_by"] || subject,
            "at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }

          {:ok, spent, %{state | challenges: Map.delete(state.challenges, nonce)}}
        else
          {:error, :consent_covers_other_tools}
        end

      {:ok, _other} ->
        {:error, :consent_belongs_to_another_client}

      :error ->
        {:error, :consent_required}
    end
  end

  defp expire(state) do
    now = System.monotonic_time(:millisecond)

    %{
      state
      | challenges:
          state.challenges
          |> Enum.reject(fn {_nonce, entry} -> entry.expires_at <= now end)
          |> Map.new()
    }
  end

  defp prompt([one]), do: "Let this session run #{one} on your machine?"

  defp prompt(names) do
    "Let this session run #{length(names)} tools on your machine: #{Enum.join(names, ", ")}?"
  end

  # -- registration -----------------------------------------------------------

  defp do_register(state, connection, specs, actor, consent) do
    tools =
      Map.new(specs, fn spec ->
        name = prefixed(spec.name)

        {name,
         %{
           name: name,
           description: Map.get(spec, :description, "A tool hosted by an attached client."),
           schema: Map.get(spec, :schema, %{"type" => "object"}),
           # `ask` by default, and deliberately not `auto`: the consent was to offering
           # the tool, not to every call the model decides to make with it. A profile
           # that says otherwise still wins, as it does for a built-in.
           default_permission: Map.get(spec, :default_permission, :ask),
           run: spec.run,
           connection: connection,
           actor: actor
         }}
      end)

    names = tools |> Map.keys() |> Enum.sort()

    state = %{
      state
      | tools: Map.merge(state.tools, tools),
        monitors: watch(state.monitors, connection)
    }

    Log.append(
      state.session_id,
      ["root"],
      :tools_registered,
      %{"tools" => names, "connection" => inspect(connection), "consent" => consent},
      actor
    )

    Log.append(
      state.session_id,
      ["root"],
      :session_tainted,
      %{"kind" => "personal_connector", "tools" => names, "actor" => subject_of(actor)},
      actor
    )

    {names, state}
  end

  defp watch(monitors, connection) do
    Map.put_new_lazy(monitors, connection, fn -> Process.monitor(connection) end)
  end

  # Only stop watching once this connection has nothing left: a partial unregister must
  # not blind us to the disconnect that would take the rest.
  defp unwatch(monitors, tools, connection) do
    if Enum.any?(tools, fn {_name, tool} -> tool.connection == connection end) do
      monitors
    else
      case Map.pop(monitors, connection) do
        {nil, rest} -> rest
        {monitor, rest} -> Process.demonitor(monitor, [:flush]) && rest
      end
    end
  end

  defp drop(state, connection, names, reason) do
    gone =
      state.tools
      |> Enum.filter(fn {name, tool} ->
        tool.connection == connection and (names == :all or name in names)
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if gone == [] do
      {[], state}
    else
      tools = Map.drop(state.tools, gone)

      monitors = unwatch(state.monitors, tools, connection)

      Log.append(state.session_id, ["root"], :tools_unregistered, %{
        "tools" => gone,
        "connection" => inspect(connection),
        "reason" => reason
      })

      {gone, %{state | tools: tools, monitors: monitors}}
    end
  end

  defp prefixed(@prefix <> _rest = name), do: name
  defp prefixed(name), do: @prefix <> name

  defp subject_of(%Event.Actor{subject: subject}) when is_binary(subject), do: subject
  defp subject_of(_actor), do: "system"
end
