defmodule Troupe.Gateway.Remote do
  @moduledoc """
  A laptop's sessions offered to the plane, so their person and the people they share
  one with can steer it from another device (#58).

  ## One connection, dialled from here

  Nothing listens on the laptop for this. While at least one session is offered and a
  client has handed the daemon a plane token (`Troupe.Gateway.Plane`), the daemon keeps
  one WebSocket open to the plane's `/v1/relay`, authenticated with that token and renewed
  on it (`auth.refresh`) each time a client links again with a fresh one. Over it the
  daemon tells the plane what it offers (`relay.sync`, `relay.offer`, `relay.withdraw`),
  and the plane relays each remote person's protocol messages to it and back
  (`relay.open`, `relay.frame`, `relay.close`), one viewer at a time.

  ## Each remote person is a connection like any other

  A viewer the plane opens becomes a `Troupe.Gateway.Connection` on a `:relay` endpoint
  (`Troupe.Gateway.Remote.Viewer` owns its frames), so a remote prompt goes through the
  same dispatcher, the same session and the same rules as one typed here: the enforced
  layer, the per-tool rules and the approvals apply to it, and nothing about the
  connection can loosen them. What it may ask is `Troupe.Protocol.Relay`'s table, held to
  the one session, which the plane checked before relaying and this module checks again.

  ## The daemon's own record decides

  The plane says who a viewer is and the role it holds them to; this module keeps its own
  record of whom it offered each session to, in `<state>/remote.json`, and a viewer gets
  the narrower of the two roles, or is closed if this record does not name them. The
  session's owner, the person linked here when it was offered, steers it from any device.
  A share is made at offer time, by subject or email, and resolved by the plane to people
  it knows; offering again replaces it. The plane's own session sharing (`session.grant`,
  share links) is for the plane's rows and does not reach here.

  ## Withdrawn at once, offline honestly

  Withdrawing closes every remote view of the session here, before the plane is told, so
  a plane that did not hear still relays nothing more. A dropped connection closes every
  view, the plane shows the session offline since the drop and queues nothing; the
  daemon dials again, backing off, and offers again exactly what its record still holds.
  A private session is never offered: it is sealed under its person's key and the plane
  holds its row, which is another promise.
  """

  use GenServer

  alias Troupe.Gateway.{Plane, Remote.Viewer}
  alias Troupe.Protocol.{Client, Endpoint, Error, Relay}

  require Logger

  @name __MODULE__
  @table :troupe_remote_offers
  @file_name "remote.json"
  @version 1
  @min_backoff_ms 1_000
  @max_backoff_ms 60_000

  defstruct offers: %{},
            device: nil,
            path: nil,
            link: nil,
            monitor: nil,
            status: :offline,
            connecting: nil,
            waiting: [],
            viewers: %{},
            backoff: @min_backoff_ms,
            retry: nil,
            since: nil,
            relay_url: nil

  # -- api --------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Offer a session to the plane, shared with `share`: a list of `%{"person" => subject or
  email, "role" => "observe" | "control"}`. Answers what `describe/1` says of it after.
  """
  @spec offer(String.t(), list(), String.t() | nil) :: {:ok, map()} | {:error, Error.t()}
  def offer(session_id, share, subject) do
    GenServer.call(@name, {:offer, session_id, share, subject}, 30_000)
  catch
    :exit, {:noproc, _} -> {:error, Error.new(:unavailable, %{reason: "not served here"})}
  end

  @doc "Withdraw a session: every remote view of it ends now."
  @spec withdraw(String.t()) :: :ok
  def withdraw(session_id) do
    GenServer.call(@name, {:withdraw, session_id})
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc "A client handed the daemon a plane token: renew the connection on it, or dial."
  @spec linked() :: :ok
  def linked, do: if(Process.whereis(@name), do: GenServer.cast(@name, :linked), else: :ok)

  @doc "The plane token was taken back: close the connection, keep the record."
  @spec unlinked() :: :ok
  def unlinked, do: if(Process.whereis(@name), do: GenServer.cast(@name, :unlinked), else: :ok)

  @doc """
  What a session's listing says of its offer: `nil` for one not offered, or its shares,
  whether the plane has it (`online`, `connecting`, `offline` with `since`) and who is
  steering it from another device now. Read from a table, so a listing never waits on
  this process, and `nil` where none runs, as on a worker.
  """
  @spec describe(String.t()) :: map() | nil
  def describe(session_id) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, session_id) do
          [{^session_id, described}] -> described
          [] -> nil
        end
    end
  end

  @doc "The role this daemon's record gives `subject` on an offered session, or `nil`."
  @spec role(String.t(), String.t() | nil) :: String.t() | nil
  def role(session_id, subject) do
    case describe(session_id) do
      %{"owner" => ^subject} when is_binary(subject) -> "control"
      %{"shares" => shares} -> Enum.find_value(shares, &(&1["subject"] == subject && &1["role"]))
      nil -> nil
    end
  end

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe remote steering")
    Process.flag(:trap_exit, true)

    if :ets.whereis(@table) == :undefined,
      do: :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    path = Keyword.get_lazy(opts, :path, fn -> Path.join(Troupe.Paths.state_dir(), @file_name) end)
    {offers, device} = read(path)

    state = %__MODULE__{
      offers: offers,
      device: device,
      path: path,
      since: now(),
      relay_url: Keyword.get(opts, :relay_url)
    }

    {:ok, publish(state), {:continue, :dial}}
  end

  @impl GenServer
  def handle_continue(:dial, state), do: {:noreply, maybe_dial(state)}

  @impl GenServer
  def handle_call({:offer, session_id, share, subject}, from, state) do
    with {:ok, session} <- offerable(session_id, subject),
         {:ok, share} <- share_param(share) do
      request = {:offer, from, session_id, workspace_label(session), share, subject}
      {:noreply, when_online(state, request)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:withdraw, session_id}, _from, state) do
    state = close_viewers(state, session_id, "withdrawn")
    had? = Map.has_key?(state.offers, session_id)
    state = %{state | offers: Map.delete(state.offers, session_id)}
    persist(state)

    if had? and state.status == :online,
      do: call_plane(state, "relay.withdraw", %{"session_id" => session_id}, :ignore)

    state = if map_size(state.offers) == 0, do: hang_up(state), else: state
    {:reply, :ok, publish(state)}
  end

  @impl GenServer
  def handle_cast(:linked, %{status: :online} = state) do
    case Plane.credentials() do
      {:ok, %{token: token}} ->
        call_plane(state, "auth.refresh", %{"auth" => %{"token" => token}}, :refreshed)
        {:noreply, state}

      _none ->
        {:noreply, state}
    end
  end

  def handle_cast(:linked, state), do: {:noreply, maybe_dial(%{state | backoff: @min_backoff_ms})}

  def handle_cast(:unlinked, state) do
    state = state |> cancel_retry() |> hang_up()
    {:noreply, publish(state)}
  end

  @impl GenServer
  # The dial, done in a task so that this process answers while it waits.
  def handle_info({:dialled, ref, result}, %{connecting: ref} = state) do
    state = %{state | connecting: nil}

    case result do
      {:ok, client} ->
        monitor = Process.monitor(client)
        state = %{state | link: client, monitor: monitor, status: :online, backoff: @min_backoff_ms}
        Logger.info("troupe-daemon: connected to the plane's relay to offer sessions for steering")
        state = sync(state)
        {:noreply, publish(drain_waiting(state))}

      {:error, reason} ->
        Logger.warning("troupe-daemon: the plane's relay could not be reached: #{inspect(reason)}")
        state = fail_waiting(state, reason)
        {:noreply, publish(schedule_retry(%{state | status: :offline, since: now()}))}
    end
  end

  def handle_info({:dialled, _stale, {:ok, client}}, state) do
    Client.close(client)
    {:noreply, state}
  end

  def handle_info({:dialled, _stale, _result}, state), do: {:noreply, state}

  def handle_info({:answered, :offer, from, session_id, subject, result}, state) do
    case result do
      {:ok, %{"shares" => shares}} ->
        offer = %{
          "owner" => subject,
          "shares" => shares,
          "offered_at" => now()
        }

        state = %{state | offers: Map.put(state.offers, session_id, offer)}
        state = narrow_viewers(state, session_id)
        persist(state)
        state = publish(state)
        GenServer.reply(from, {:ok, describe(session_id)})
        {:noreply, state}

      {:error, error} ->
        GenServer.reply(from, {:error, plane_error(error)})
        {:noreply, state}
    end
  end

  def handle_info({:answered, :sync, _from, _session_id, _subject, result}, state) do
    case result do
      {:ok, %{"offers" => offers}} when is_list(offers) ->
        resolved = Map.new(offers, &{&1["session_id"], &1["shares"]})

        offers =
          Map.new(state.offers, fn {id, offer} ->
            {id, Map.put(offer, "shares", Map.get(resolved, id, offer["shares"]))}
          end)

        {:noreply, publish(%{state | offers: offers})}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:answered, _what, _from, _session_id, _subject, _result}, state),
    do: {:noreply, state}

  def handle_info({:troupe_notification, "relay.open", params}, state) do
    {:noreply, publish(open_viewer(state, params))}
  end

  def handle_info({:troupe_notification, "relay.frame", %{"viewer" => id, "data" => data}}, state) do
    case Map.fetch(state.viewers, id) do
      {:ok, viewer} -> Viewer.frame(viewer.pid, data)
      :error -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:troupe_notification, "relay.close", %{"viewer" => id}}, state) do
    case Map.fetch(state.viewers, id) do
      {:ok, viewer} -> Viewer.close(viewer.pid, "the person left")
      :error -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:troupe_notification, _method, _params}, state), do: {:noreply, state}

  # Nothing the plane asks of the daemon is a request; an unknown one is answered so the
  # plane is not left waiting.
  def handle_info({:troupe_request, id, method, _params}, %{link: link} = state) when is_pid(link) do
    Client.respond_error(link, id, "#{method} is not something this daemon does")
    {:noreply, state}
  end

  def handle_info({:troupe_disconnected, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, _client, reason}, %{monitor: monitor} = state) do
    Logger.info("troupe-daemon: the plane's relay closed (#{inspect(reason)})")

    state =
      %{state | link: nil, monitor: nil, status: :offline, since: now()}
      |> close_all_viewers("the laptop went offline")
      |> schedule_retry()

    {:noreply, publish(state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Enum.find(state.viewers, fn {_id, viewer} -> viewer.pid == pid end) do
      nil ->
        {:noreply, state}

      {id, _viewer} ->
        if state.link, do: Client.notify(state.link, "relay.close", %{"viewer" => id})
        {:noreply, publish(%{state | viewers: Map.delete(state.viewers, id)})}
    end
  end

  def handle_info(:retry, state), do: {:noreply, maybe_dial(%{state | retry: nil})}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    close_all_viewers(state, "the daemon stopped")
    if state.link, do: Client.close(state.link)
    :ok
  end

  # -- offering ---------------------------------------------------------------

  # The session is here, is not private, and is the linked person's: one made while
  # somebody else was linked is theirs to offer at their next link. And there is a plane
  # to offer it to.
  defp offerable(session_id, subject) do
    with {:ok, session} <- session(session_id),
         :ok <- not_private(session),
         :ok <- linked(subject),
         :ok <- owned(session, subject) do
      {:ok, session}
    end
  end

  defp session(session_id) do
    case Troupe.get_session(session_id) do
      nil -> {:error, Error.new(:not_found, %{kind: "session", id: session_id})}
      session -> {:ok, session}
    end
  end

  defp not_private(%{kind: "private"}) do
    {:error,
     Error.new(:forbidden, %{
       reason:
         "a private session is never offered to the plane: it is sealed under your own key, " <>
           "and steering it from elsewhere is claiming it there (session.claim)"
     })}
  end

  defp not_private(_session), do: :ok

  defp linked(subject) do
    case Plane.credentials() do
      {:ok, %{subject: ^subject}} when is_binary(subject) ->
        :ok

      {:error, {:update_required, sentence}} ->
        {:error, Error.new(:unavailable, %{reason: sentence})}

      _unlinked ->
        {:error,
         Error.new(:unavailable, %{
           reason: "sign in to a plane first: a session is offered to the plane you are signed in to"
         })}
    end
  end

  defp owned(%{owner: owner}, subject) when owner in [nil, subject], do: :ok

  defp owned(%{owner: owner}, _subject) do
    {:error, Error.new(:forbidden, %{reason: "the session is #{owner}'s, who offers it at their own link"})}
  end

  defp share_param(nil), do: {:ok, []}

  defp share_param(share) when is_list(share) do
    Enum.reduce_while(share, {:ok, []}, fn
      %{"person" => person} = entry, {:ok, acc} when is_binary(person) and person != "" ->
        role = Map.get(entry, "role") || "observe"

        if role in Relay.roles(),
          do: {:cont, {:ok, acc ++ [%{"person" => String.trim(person), "role" => role}]}},
          else: {:halt, {:error, Error.new(:invalid_params, %{field: "share", value: role})}}

      _other, _acc ->
        {:halt,
         {:error,
          Error.new(:invalid_params, %{
            field: "share",
            reason: "each is {person, role}: a subject or email, and observe or control"
          })}}
    end)
  end

  defp share_param(_other), do: {:error, Error.new(:invalid_params, %{field: "share"})}

  # What the plane lists the session as: the workspace's last name, never its path.
  defp workspace_label(%{workspace: workspace}) when is_binary(workspace),
    do: Path.basename(workspace)

  defp workspace_label(_session), do: nil

  # -- the connection ---------------------------------------------------------

  defp when_online(%{status: :online} = state, request), do: run(state, request)

  defp when_online(state, request) do
    state = %{state | waiting: state.waiting ++ [request]}
    dial(state)
  end

  defp drain_waiting(state) do
    Enum.reduce(state.waiting, %{state | waiting: []}, &run(&2, &1))
  end

  defp fail_waiting(state, reason) do
    Enum.each(state.waiting, fn {:offer, from, _id, _label, _share, _subject} ->
      GenServer.reply(
        from,
        {:error, Error.new(:unavailable, %{reason: "the plane could not be reached: #{describe_reason(reason)}"})}
      )
    end)

    %{state | waiting: []}
  end

  defp run(state, {:offer, from, session_id, label, share, subject}) do
    params = %{"session_id" => session_id, "workspace" => label, "share" => share}
    call_plane(state, "relay.offer", params, {:offer, from, session_id, subject})
    state
  end

  # A dial with something to offer and a token to offer it with.
  defp maybe_dial(state) do
    if state.offers != %{} and owned_offers(state) != %{}, do: dial(state), else: state
  end

  defp dial(%{status: :online} = state), do: state
  defp dial(%{connecting: ref} = state) when is_reference(ref), do: state

  defp dial(state) do
    case Plane.credentials() do
      {:ok, %{url: url, token: token}} ->
        ref = make_ref()
        owner = self()
        # The plane's own `/v1/relay`, unless something stands in for it (a test's).
        relay =
          state.relay_url || Application.get_env(:troupe_gateway, :relay_url) || relay_url(url)

        Task.start(fn ->
          result =
            Client.connect(
              url: relay,
              token: token,
              owner: owner,
              client_info: %{"name" => "troupe-daemon", "version" => version()},
              capabilities: %{"relay" => true, "device" => state.device}
            )

          send(owner, {:dialled, ref, result})
        end)

        %{state | connecting: ref, status: :connecting}

      {:error, reason} ->
        fail_waiting(%{state | status: :offline}, reason)
    end
  end

  defp hang_up(state) do
    state = close_all_viewers(state, "the laptop stopped offering")
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    if state.link, do: Client.close(state.link)
    %{state | link: nil, monitor: nil, status: :offline, since: now(), connecting: nil}
  end

  defp schedule_retry(state) do
    state = cancel_retry(state)

    if owned_offers(state) != %{} and match?({:ok, _}, Plane.credentials()) do
      retry = Process.send_after(self(), :retry, state.backoff)
      %{state | retry: retry, backoff: min(state.backoff * 2, @max_backoff_ms)}
    else
      state
    end
  end

  defp cancel_retry(%{retry: nil} = state), do: state

  defp cancel_retry(state) do
    Process.cancel_timer(state.retry)
    %{state | retry: nil}
  end

  # On every connection, what the record holds of the linked person's: the plane keeps
  # these and drops any other it had from this device, so a session withdrawn while the
  # laptop was away is not offered again, and one still offered is.
  defp sync(state) do
    offers =
      state
      |> owned_offers()
      |> Enum.filter(fn {id, _offer} -> Troupe.get_session(id) != nil end)
      |> Enum.map(fn {id, offer} ->
        %{
          "session_id" => id,
          "workspace" => id |> Troupe.get_session() |> workspace_label(),
          "share" => Enum.map(offer["shares"], &%{"person" => &1["subject"], "role" => &1["role"]})
        }
      end)

    call_plane(state, "relay.sync", %{"offers" => offers}, :sync)
    state
  end

  defp owned_offers(state) do
    case Plane.credentials() do
      {:ok, %{subject: subject}} -> Map.filter(state.offers, fn {_id, o} -> o["owner"] == subject end)
      _none -> %{}
    end
  end

  # A request to the plane, answered to this process, so it never waits on the network.
  defp call_plane(%{link: link}, method, params, tag) when is_pid(link) do
    owner = self()

    Task.start(fn ->
      result =
        try do
          Client.call(link, method, params)
        catch
          :exit, reason -> {:error, {:closed, reason}}
        end

      case tag do
        :ignore -> :ok
        :refreshed -> :ok
        {:offer, from, id, subject} -> send(owner, {:answered, :offer, from, id, subject, result})
        :sync -> send(owner, {:answered, :sync, nil, nil, nil, result})
      end
    end)
  end

  defp call_plane(_state, _method, _params, {:offer, from, _id, _subject}) do
    GenServer.reply(from, {:error, Error.new(:unavailable, %{reason: "the plane is not connected"})})
  end

  defp call_plane(_state, _method, _params, _tag), do: :ok

  # -- viewers ----------------------------------------------------------------

  defp open_viewer(state, %{"viewer" => id, "session_id" => session_id} = params)
       when is_binary(id) and is_binary(session_id) do
    person = Map.get(params, "person") || %{}
    subject = person["subject"]
    role = Relay.narrower(params["role"], role(session_id, subject))

    cond do
      not Map.has_key?(state.offers, session_id) or Troupe.get_session(session_id) == nil ->
        refuse_viewer(state, id, "the session is not offered")

      is_nil(subject) or is_nil(role) ->
        refuse_viewer(state, id, "the laptop has not shared the session with you")

      true ->
        principal = %{
          "subject" => subject,
          "display_name" => person["display_name"] || subject,
          "kind" => "user",
          "via" => "plane",
          "role" => role
        }

        endpoint = endpoint(session_id, principal)
        {:ok, pid} = Viewer.start(id, state.link, endpoint)
        Process.monitor(pid)

        viewer = %{pid: pid, session_id: session_id, principal: principal, role: role}
        %{state | viewers: Map.put(state.viewers, id, viewer)}
    end
  end

  defp open_viewer(state, _params), do: state

  defp refuse_viewer(state, id, reason) do
    if state.link, do: Client.notify(state.link, "relay.close", %{"viewer" => id, "reason" => reason})
    state
  end

  # The person's connection: who the plane said they are, at the narrower role, held to
  # the one session at every command against this daemon's record as it stands then.
  defp endpoint(session_id, principal) do
    subject = principal["subject"]

    Endpoint.relay(fn _params -> {:ok, principal, Relay.scopes(principal["role"])} end,
      guard: fn _claims, method, params ->
        case role(session_id, subject) do
          nil ->
            {:error, Error.new(:forbidden, %{reason: "the session is no longer shared with you"})}

          held ->
            role = Relay.narrower(principal["role"], held)

            with :ok <- Relay.check(method, params, session_id, role),
                 do: {:ok, Relay.scopes(role)}
        end
      end,
      narrow: fn _claims, method, result -> narrow(session_id, method, result) end
    )
  end

  defp narrow(session_id, method, %{"sessions" => sessions} = result)
       when method in ["session.list", "fleet.get"] and is_list(sessions) do
    %{result | "sessions" => Enum.filter(sessions, &(&1["id"] == session_id))}
  end

  defp narrow(_session_id, _method, result), do: result

  defp close_viewers(state, session_id, reason) do
    {closing, kept} = Enum.split_with(state.viewers, fn {_id, v} -> v.session_id == session_id end)
    Enum.each(closing, fn {id, viewer} -> close_viewer(state, id, viewer, reason) end)
    %{state | viewers: Map.new(kept)}
  end

  defp close_all_viewers(state, reason) do
    Enum.each(state.viewers, fn {id, viewer} -> close_viewer(state, id, viewer, reason) end)
    %{state | viewers: %{}}
  end

  defp close_viewer(state, id, viewer, reason) do
    Viewer.close(viewer.pid, reason)

    if state.link,
      do: Client.notify(state.link, "relay.close", %{"viewer" => id, "reason" => reason})
  end

  # A share made narrower or taken away reaches the people already steering: one no longer
  # named is closed, and the guard holds the rest to the role at their next command.
  defp narrow_viewers(state, session_id) do
    offer = Map.get(state.offers, session_id)

    {gone, kept} =
      Enum.split_with(state.viewers, fn {_id, v} ->
        v.session_id == session_id and v.principal["subject"] != offer["owner"] and
          not Enum.any?(offer["shares"], &(&1["subject"] == v.principal["subject"]))
      end)

    Enum.each(gone, fn {id, viewer} -> close_viewer(state, id, viewer, "no longer shared with you") end)
    %{state | viewers: Map.new(kept)}
  end

  # -- the record -------------------------------------------------------------

  defp publish(state) do
    :ets.delete_all_objects(@table)

    Enum.each(state.offers, fn {id, offer} ->
      steering =
        state.viewers
        |> Map.values()
        |> Enum.filter(&(&1.session_id == id))
        |> Enum.map(fn v ->
          %{"subject" => v.principal["subject"], "display_name" => v.principal["display_name"], "role" => v.role}
        end)
        |> Enum.uniq()

      described = %{
        "owner" => offer["owner"],
        "shares" => offer["shares"],
        "offered_at" => offer["offered_at"],
        "state" => Atom.to_string(state.status),
        "since" => if(state.status != :online, do: state.since),
        "steering" => steering
      }

      :ets.insert(@table, {id, described})
    end)

    state
  end

  defp read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"version" => @version, "offers" => %{} = offers} = doc} <- Jason.decode(text) do
      {offers, doc["device"] || device()}
    else
      _none -> {%{}, device()}
    end
  end

  defp persist(state) do
    temporary = state.path <> ".#{System.unique_integer([:positive])}.tmp"

    text =
      Jason.encode!(%{"version" => @version, "device" => state.device, "offers" => state.offers},
        pretty: true
      )

    with :ok <- File.mkdir_p(Path.dirname(state.path)),
         :ok <- File.write(temporary, text <> "\n"),
         :ok <- File.rename(temporary, state.path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        Logger.warning("troupe-daemon: #{state.path} could not be written: #{inspect(reason)}")
    end
  end

  defp device, do: "d-" <> (12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

  defp relay_url(plane_url) do
    uri = URI.parse(String.trim_trailing(plane_url, "/"))
    scheme = if uri.scheme == "https", do: "wss", else: "ws"
    URI.to_string(%{uri | scheme: scheme, path: (uri.path || "") <> "/v1/relay"})
  end

  defp plane_error(%Error{} = error), do: error

  defp plane_error(other),
    do: Error.new(:unavailable, %{reason: "the plane did not answer: #{describe_reason(other)}"})

  defp describe_reason(%Error{message: message, data: %{"reason" => reason}}), do: "#{message}: #{reason}"
  defp describe_reason(%Error{message: message}), do: message
  defp describe_reason(reason), do: inspect(reason)

  defp version, do: to_string(Application.spec(:troupe_gateway, :vsn) || "dev")

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
