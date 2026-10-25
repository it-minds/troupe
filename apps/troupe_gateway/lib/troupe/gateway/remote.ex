defmodule Troupe.Gateway.Remote do
  @moduledoc """
  A laptop's sessions offered to the plane, so their person and the people they share
  one with can steer it from another device (#58).

  ## One connection, dialled from here

  Nothing listens on the laptop for this. While at least one session is offered, the
  daemon keeps one WebSocket open to the plane's `/v1/relay`. Over it the daemon tells the
  plane what it offers (`relay.sync`, `relay.offer`, `relay.withdraw`), and the plane
  relays each remote person's protocol messages to it and back (`relay.open`,
  `relay.frame`, `relay.close`), one viewer at a time.

  ## Its own sign-in, while anything is offered

  A client's plane token (`Troupe.Gateway.Plane`) lives fifteen minutes and is renewed only
  while that client runs, so an offer that rode on it went offline when the client closed.
  So at the first offer the daemon asks the plane for a grant of its own (`remote.grant`,
  with the client's token, naming this device), and keeps it in the operating system's
  credential store (`Troupe.Keyring`), never a file. It exchanges the grant at the plane's
  `/auth/relay` for a token of the laptop's door alone, dials with that, and exchanges it
  again before each token runs out, renewing on the open socket (`auth.refresh`). A
  daemon that restarts with something offered reads the grant back and dials again with
  no client at all, so where the daemon starts at login (`Troupe.StartAtLogin`) a reboot
  brings every offer back; where it does not, an offer is said to last until this machine
  restarts, since nothing starts the daemon then until a client does.

  Withdrawing the last offer, signing out (`identity.sign_out` for this plane and person,
  which a client's sign-out and `troupe logout` send) and unlinking the daemon release the
  grant at the plane, take it out of the store and close the connection. The record is
  kept, so the next link with a token offers the same sessions again. A machine with no
  store keeps the grant in memory and says so: the offer then lasts as long as the daemon.

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
  alias Troupe.Keyring.Steering
  alias Troupe.Protocol.{Client, Endpoint, Error, Relay}

  require Logger

  @name __MODULE__
  @table :troupe_remote_offers
  @file_name "remote.json"
  @version 1
  @min_backoff_ms 1_000
  @max_backoff_ms 60_000
  # The daemon's own token is exchanged again this long before it runs out, and a renewal
  # the plane did not answer is tried again after the second.
  @renew_before_s 120
  @renew_retry_ms 30_000
  @http_timeout_ms 15_000

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
            relay_url: nil,
            # The daemon's own sign-in: `%{url, subject, grant, token, expires_at}`, the
            # grant as the credential store keeps it and the token it was last exchanged for.
            sign_in: nil,
            keyring: nil,
            renew: nil,
            renewing: nil,
            refused: nil,
            # The offers read back from the record as this process started: a listing says
            # they came back after a restart until they are offered again.
            restored: MapSet.new()

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

  @doc """
  The daemon was unlinked, or linked to somebody else: its own sign-in is released and
  the connection closed. The record is kept.
  """
  @spec unlinked() :: :ok
  def unlinked do
    GenServer.call(@name, :unlinked, 30_000)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc """
  The person signed out (`identity.sign_out`): where the daemon's own sign-in is for this
  plane and this person (`subject` nil is whoever it is for), it is released, taken out of
  the credential store and the connection closed. Answers whether there was one.
  """
  @spec signed_out(String.t(), String.t() | nil) :: boolean()
  def signed_out(plane_url, subject) do
    GenServer.call(@name, {:signed_out, plane_url, subject}, 30_000)
  catch
    :exit, {:noproc, _} -> false
  end

  @doc """
  Whether the daemon is keeping a session offered now: something offered and its own
  sign-in to offer it with. The idle watch stays up for it. Read from a table, so the
  watch never waits on this process.
  """
  @spec offering?() :: boolean()
  def offering? do
    case :ets.whereis(@table) do
      :undefined -> false
      table -> match?([{:offering, true}], :ets.lookup(table, :offering))
    end
  end

  @doc """
  The name the daemon's own sign-in is kept under in the credential store
  (`Troupe.Keyring.Steering`): one per state directory, so a second daemon with homes of
  its own keeps a sign-in of its own.
  """
  @spec keyring_name(Path.t()) :: String.t()
  def keyring_name(state_dir \\ Troupe.Paths.state_dir()), do: Steering.name(state_dir)

  @doc """
  What a session's listing says of its offer: `nil` for one not offered, or its shares,
  whether the plane has it (`online`, `connecting`, `offline` with `since`) and who is
  steering it from another device now. `lasts` says whether it comes back after this
  machine restarts: `across_restarts` where the daemon starts at login, which reads its
  own sign-in back and offers it again, and `until_restart` where nothing starts the
  daemon then. `restored` is an offer read back from the record as the daemon started,
  until it is offered again. Read from a table, so a listing never waits on this process,
  and `nil` where none runs, as on a worker.
  """
  @spec describe(String.t()) :: map() | nil
  def describe(session_id) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, session_id) do
          [{^session_id, described}] -> Map.put(described, "lasts", lasts())
          [] -> nil
        end
    end
  end

  # Asked at each listing rather than kept, so `troupe-daemon login on` after the offer is
  # what the next listing says.
  defp lasts,
    do: if(Troupe.StartAtLogin.enabled?(), do: "across_restarts", else: "until_restart")

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
      restored: offers |> Map.keys() |> MapSet.new(),
      device: device,
      path: path,
      since: now(),
      relay_url: Keyword.get(opts, :relay_url),
      keyring: Keyword.get_lazy(opts, :keyring, fn -> keyring_name(Path.dirname(path)) end)
    }

    {:ok, publish(state), {:continue, :dial}}
  end

  # The credential store is read here rather than in `init/1`, which a slow store would hold
  # the daemon's start on, and only when something is offered: nothing else needs it.
  @impl GenServer
  def handle_continue(:dial, state) do
    state = if state.offers != %{}, do: %{state | sign_in: stored(state)}, else: state
    {:noreply, publish(maybe_dial(state))}
  end

  @impl GenServer
  def handle_call({:offer, session_id, share, subject}, from, state) do
    with {:ok, session} <- offerable(state, session_id, subject),
         {:ok, share} <- share_param(share) do
      request = {:offer, from, session_id, workspace_label(session), share, subject}
      {:noreply, publish(when_online(%{state | refused: nil}, request))}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:withdraw, session_id}, _from, state) do
    state = close_viewers(state, session_id, "withdrawn")
    had? = Map.has_key?(state.offers, session_id)

    state = %{
      state
      | offers: Map.delete(state.offers, session_id),
        restored: MapSet.delete(state.restored, session_id)
    }

    persist(state)
    last? = owned_offers(state) == %{}

    cond do
      had? and state.status == :online and last? ->
        # Said before the connection closes, so the plane does not show it offline instead.
        withdraw_now(state, session_id)

      had? and state.status == :online ->
        call_plane(state, "relay.withdraw", %{"session_id" => session_id}, :ignore)

      true ->
        :ok
    end

    state = if last?, do: state |> cancel_retry() |> hang_up() |> release(), else: state
    {:reply, :ok, publish(state)}
  end

  def handle_call(:unlinked, _from, state) do
    state = state |> cancel_retry() |> hang_up() |> release()
    {:reply, :ok, publish(state)}
  end

  def handle_call({:signed_out, url, subject}, _from, %{sign_in: %{} = sign_in} = state) do
    if same_plane?(sign_in.url, url) and subject in [nil, sign_in.subject] do
      state = state |> cancel_retry() |> hang_up() |> release()
      {:reply, true, publish(state)}
    else
      {:reply, false, state}
    end
  end

  def handle_call({:signed_out, _url, _subject}, _from, state) do
    {:reply, false, publish(state |> cancel_retry() |> hang_up())}
  end

  # A client linked with a token: what is offered and waited for a sign-in is offered now.
  # A connection up on the daemon's own sign-in needs nothing from the client's token.
  @impl GenServer
  def handle_cast(:linked, %{status: :online} = state), do: {:noreply, state}

  def handle_cast(:linked, state),
    do: {:noreply, publish(maybe_dial(%{state | backoff: @min_backoff_ms, refused: nil}))}

  @impl GenServer
  # The grant, asked in a task so that this process answers while it waits.
  def handle_info({:granted, ref, result}, %{connecting: ref} = state) do
    state = %{state | connecting: nil}

    case result do
      {:ok, sign_in} ->
        if sign_in.stored != :ok do
          Logger.warning(
            "troupe-daemon: the operating system's credential store did not take the sign-in for " <>
              "steering (#{inspect(sign_in.stored)}); it is kept in memory, and an offer ends with the daemon"
          )
        end

        Logger.info("troupe-daemon: signed in to #{sign_in.url} for steering, as this device")
        {:noreply, publish(dial(%{state | sign_in: Map.delete(sign_in, :stored)}))}

      {:error, reason} ->
        Logger.warning("troupe-daemon: the plane gave no sign-in for steering: #{describe_reason(reason)}")
        state = fail_waiting(%{state | status: :offline, since: now()}, reason)
        state = if refusal?(reason), do: %{state | refused: reason}, else: schedule_retry(state)
        {:noreply, publish(state)}
    end
  end

  # A sign-in that arrives after the person signed out or withdrew is let go at once.
  def handle_info({:granted, _stale, {:ok, sign_in}}, %{sign_in: nil} = state) do
    {:noreply, release(%{state | sign_in: Map.delete(sign_in, :stored)})}
  end

  def handle_info({:granted, _stale, _result}, state), do: {:noreply, state}

  # The dial, done in a task so that this process answers while it waits.
  def handle_info({:dialled, ref, result}, %{connecting: ref} = state) do
    state = %{state | connecting: nil}

    case result do
      {:ok, client, auth} ->
        monitor = Process.monitor(client)

        state = %{
          state
          | link: client,
            monitor: monitor,
            status: :online,
            backoff: @min_backoff_ms,
            sign_in: Map.merge(state.sign_in, auth)
        }

        Logger.info("troupe-daemon: connected to the plane's relay to offer sessions for steering")
        state = state |> schedule_renew() |> sync()
        {:noreply, publish(drain_waiting(state))}

      {:error, {:grant_refused, status, reason} = refused} ->
        Logger.warning("troupe-daemon: the plane refused this device's sign-in for steering (#{status}): #{reason}")
        state = fail_waiting(%{forget(state) | status: :offline, since: now()}, refused)
        state = if status == 403, do: %{state | refused: refused}, else: schedule_retry(state)
        {:noreply, publish(state)}

      {:error, reason} ->
        Logger.warning("troupe-daemon: the plane's relay could not be reached: #{inspect(reason)}")
        state = fail_waiting(state, reason)
        {:noreply, publish(schedule_retry(%{state | status: :offline, since: now()}))}
    end
  end

  def handle_info({:dialled, _stale, {:ok, client, _auth}}, state) do
    Client.close(client)
    {:noreply, state}
  end

  def handle_info({:dialled, _stale, _result}, state), do: {:noreply, state}

  # The daemon's own token, exchanged again before it runs out and renewed on the open
  # socket; the plane's warning two minutes before asks for the same.
  def handle_info(:renew, state), do: {:noreply, renew(%{state | renew: nil})}

  def handle_info({:troupe_notification, "auth.expiring", _params}, state), do: {:noreply, renew(state)}

  def handle_info({:renewed, ref, result}, %{renewing: ref} = state) do
    state = %{state | renewing: nil}

    case result do
      {:ok, auth} ->
        call_plane(state, "auth.refresh", %{"auth" => %{"token" => auth.token}}, :ignore)
        {:noreply, schedule_renew(%{state | sign_in: Map.merge(state.sign_in, auth)})}

      {:error, {:grant_refused, status, reason} = refused} ->
        Logger.warning("troupe-daemon: the plane refused this device's sign-in for steering (#{status}): #{reason}")
        state = state |> hang_up() |> forget()
        state = if status == 403, do: %{state | refused: refused}, else: schedule_retry(state)
        {:noreply, publish(state)}

      {:error, reason} ->
        Logger.info("troupe-daemon: the sign-in for steering was not renewed yet: #{inspect(reason)}")
        {:noreply, %{state | renew: Process.send_after(self(), :renew, @renew_retry_ms)}}
    end
  end

  def handle_info({:renewed, _stale, _result}, state), do: {:noreply, state}

  def handle_info({:answered, :offer, from, session_id, subject, result}, state) do
    case result do
      {:ok, %{"shares" => shares}} ->
        offer = %{
          "owner" => subject,
          "shares" => shares,
          "offered_at" => now()
        }

        state = %{
          state
          | offers: Map.put(state.offers, session_id, offer),
            restored: MapSet.delete(state.restored, session_id)
        }

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
  # to offer it to: a client's token, or the daemon's own sign-in for this person.
  defp offerable(state, session_id, subject) do
    with {:ok, session} <- session(session_id),
         :ok <- not_private(session),
         :ok <- linked(state, subject),
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

  defp linked(%{sign_in: %{subject: subject}}, subject) when is_binary(subject), do: :ok

  defp linked(_state, subject) do
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
  defp when_online(state, request), do: connect(%{state | waiting: state.waiting ++ [request]})

  defp drain_waiting(state) do
    Enum.reduce(state.waiting, %{state | waiting: []}, &run(&2, &1))
  end

  defp fail_waiting(state, reason) do
    error = waiting_error(reason)

    Enum.each(state.waiting, fn {:offer, from, _id, _label, _share, _subject} ->
      GenServer.reply(from, {:error, error})
    end)

    %{state | waiting: []}
  end

  # What an offer that could not be made is answered: the plane's own refusal where it
  # refused, which names the team that does not allow offering, or why it was not reached.
  defp waiting_error({:rpc, %{"code" => code, "message" => message} = error}),
    do: %Error{code: code, message: message, data: error["data"]}

  defp waiting_error({:grant_refused, 403, reason}), do: Error.new(:forbidden, %{reason: reason})

  defp waiting_error({:grant_refused, _status, reason}) do
    Error.new(:unavailable, %{
      reason: "the plane no longer takes this device's sign-in (#{reason}); offer it again to sign in again"
    })
  end

  defp waiting_error({:update_required, sentence}), do: Error.new(:unavailable, %{reason: sentence})

  defp waiting_error(:unlinked) do
    Error.new(:unavailable, %{
      reason: "sign in to a plane first: a session is offered to the plane you are signed in to"
    })
  end

  defp waiting_error(reason),
    do: Error.new(:unavailable, %{reason: "the plane could not be reached: #{describe_reason(reason)}"})

  # A refusal the plane will give again whenever it is asked: a team that does not allow
  # offering. Asked again at the next offer or link, and not on a timer.
  defp refusal?({:rpc, %{"code" => -32_004}}), do: true
  defp refusal?(_reason), do: false

  defp run(state, {:offer, from, session_id, label, share, subject}) do
    params = %{"session_id" => session_id, "workspace" => label, "share" => share}
    call_plane(state, "relay.offer", params, {:offer, from, session_id, subject})
    state
  end

  # A dial with something to offer and a sign-in to offer it with: the daemon's own, or a
  # client's token to ask the plane for one.
  defp maybe_dial(state) do
    if owned_offers(state) != %{} and state.refused == nil and (state.sign_in != nil or client_linked?()),
      do: connect(state),
      else: state
  end

  defp connect(%{status: :online} = state), do: state
  defp connect(%{connecting: ref} = state) when is_reference(ref), do: state
  defp connect(%{sign_in: nil} = state), do: grant(state)
  defp connect(state), do: dial(state)

  # The daemon's own sign-in, asked of the plane with the token a client handed it, naming
  # this device, and written to the credential store before it is used, so a daemon that
  # stops with something offered finds it again.
  defp grant(state) do
    case Plane.credentials() do
      {:ok, %{url: url, subject: subject}} when is_binary(subject) ->
        ref = make_ref()
        owner = self()
        device = state.device
        keyring = state.keyring

        Task.start(fn -> send(owner, {:granted, ref, ask_grant(url, subject, device, keyring)}) end)
        %{state | connecting: ref, status: :connecting}

      {:ok, _no_subject} ->
        fail_waiting(%{state | status: :offline}, :unlinked)

      {:error, reason} ->
        fail_waiting(%{state | status: :offline}, reason)
    end
  end

  defp ask_grant(url, subject, device, keyring) do
    case Plane.call("remote.grant", %{"device" => device}) do
      {:ok, %{"grant" => grant}} when is_binary(grant) ->
        sign_in = %{url: url, subject: subject, grant: grant}
        {:ok, Map.put(sign_in, :stored, store(keyring, sign_in))}

      {:ok, other} ->
        {:error, {:unexpected, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dial(state) do
    ref = make_ref()
    owner = self()
    sign_in = state.sign_in
    device = state.device

    # The plane's own `/v1/relay`, unless something stands in for it (a test's).
    relay =
      state.relay_url || Application.get_env(:troupe_gateway, :relay_url) || relay_url(sign_in.url)

    Task.start(fn ->
      result =
        with {:ok, auth} <- exchange(sign_in),
             {:ok, client} <-
               Client.connect(
                 url: relay,
                 token: auth.token,
                 owner: owner,
                 client_info: %{"name" => "troupe-daemon", "version" => version()},
                 capabilities: %{"relay" => true, "device" => device}
               ) do
          {:ok, client, auth}
        end

      send(owner, {:dialled, ref, result})
    end)

    %{state | connecting: ref, status: :connecting}
  end

  # The grant for a token of the laptop's door, `POST <plane>/auth/relay`. A plane that no
  # longer holds the grant says 401, and one whose person's team forbids offering 403: the
  # sign-in is over either way.
  defp exchange(%{url: url, grant: grant}) do
    case Req.post(String.trim_trailing(url, "/") <> "/auth/relay",
           json: %{"grant" => grant},
           retry: false,
           receive_timeout: @http_timeout_ms
         ) do
      {:ok, %{status: 200, body: %{"token" => token} = body}} when is_binary(token) ->
        {:ok, %{token: token, expires_at: body["expires_at"]}}

      {:ok, %{status: status, body: body}} when status in [401, 403] ->
        {:error, {:grant_refused, status, refusal_text(body)}}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refusal_text(%{"reason" => reason}) when is_binary(reason), do: reason
  defp refusal_text(%{"error" => error}) when is_binary(error), do: error
  defp refusal_text(body) when is_binary(body) and body != "", do: body
  defp refusal_text(_body), do: "refused"

  defp renew(%{status: :online, renewing: nil, sign_in: %{} = sign_in} = state) do
    ref = make_ref()
    owner = self()
    Task.start(fn -> send(owner, {:renewed, ref, exchange(sign_in)}) end)
    %{cancel_renew(state) | renewing: ref}
  end

  defp renew(state), do: state

  defp schedule_renew(%{sign_in: %{expires_at: exp}} = state) when is_integer(exp) do
    state = cancel_renew(state)
    ms = max((exp - @renew_before_s - System.system_time(:second)) * 1000, 0)
    %{state | renew: Process.send_after(self(), :renew, ms)}
  end

  defp schedule_renew(state), do: state

  defp cancel_renew(%{renew: nil} = state), do: state

  defp cancel_renew(state) do
    Process.cancel_timer(state.renew)
    %{state | renew: nil}
  end

  # The grant goes: out of the credential store now, and from the plane as soon as it
  # answers, which is the plane's record that this device no longer speaks for its person.
  defp release(%{sign_in: nil} = state), do: state

  defp release(%{sign_in: sign_in} = state) do
    Task.start(fn ->
      Req.post(String.trim_trailing(sign_in.url, "/") <> "/auth/relay/release",
        json: %{"grant" => sign_in.grant},
        retry: false,
        receive_timeout: @http_timeout_ms
      )
    end)

    forget(state)
  end

  defp forget(state) do
    case Steering.delete(state.keyring) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "troupe-daemon: the sign-in for steering could not be taken out of the credential store: " <>
            inspect(reason)
        )
    end

    %{cancel_renew(state) | sign_in: nil, renewing: nil}
  end

  # The sign-in the credential store holds for this daemon, or nil.
  defp stored(state) do
    case Steering.read(state.keyring) do
      {:ok, sign_in} ->
        sign_in

      :none ->
        nil

      {:error, reason} ->
        Logger.warning(
          "troupe-daemon: the credential store could not be read for the sign-in for steering: " <>
            inspect(reason)
        )

        nil
    end
  end

  defp store(keyring, sign_in), do: Steering.write(keyring, sign_in)

  # Said and answered before the connection goes, so the plane drops the row rather than
  # showing a laptop that withdrew as one that is away.
  defp withdraw_now(%{link: link}, session_id) do
    Client.call(link, "relay.withdraw", %{"session_id" => session_id}, 5_000)
  catch
    :exit, _reason -> :ok
  end

  defp hang_up(state) do
    state = close_all_viewers(state, "the laptop stopped offering")
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    if state.link, do: Client.close(state.link)

    %{
      cancel_renew(state)
      | link: nil,
        monitor: nil,
        status: :offline,
        since: now(),
        connecting: nil,
        renewing: nil
    }
  end

  defp schedule_retry(state) do
    state = cancel_retry(state)

    if owned_offers(state) != %{} and state.refused == nil and (state.sign_in != nil or client_linked?()) do
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

  # The offers the connection carries: the daemon's own sign-in's person's, or before it
  # has one, those of the person a client linked.
  defp owned_offers(state) do
    case person(state) do
      nil -> %{}
      subject -> Map.filter(state.offers, fn {_id, o} -> o["owner"] == subject end)
    end
  end

  defp person(%{sign_in: %{subject: subject}}), do: subject

  defp person(_state) do
    case Plane.credentials() do
      {:ok, %{subject: subject}} -> subject
      _none -> nil
    end
  end

  defp client_linked? do
    case Plane.credentials() do
      {:ok, %{subject: subject}} when is_binary(subject) -> true
      _none -> false
    end
  end

  defp same_plane?(a, b) when is_binary(a) and is_binary(b),
    do: String.trim_trailing(a, "/") == String.trim_trailing(b, "/")

  defp same_plane?(_a, _b), do: false

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
        "steering" => steering,
        "restored" => MapSet.member?(state.restored, id)
      }

      :ets.insert(@table, {id, described})
    end)

    :ets.insert(@table, {:offering, state.sign_in != nil and owned_offers(state) != %{}})
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
