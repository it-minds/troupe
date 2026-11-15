defmodule Troupe.Plane.Remote.Viewer do
  @moduledoc """
  One person steering a laptop's session from another device: `GET /v1/relay/session`.

  The person's client speaks the protocol as it would to a pod, with the token
  `remote.open` gave it. This process checks the token, the offer and the person's role,
  finds the laptop's connection wherever it is held (`Troupe.Plane.Remote.laptop/1`), and
  from then on relays each message both ways, checking each request against
  `Troupe.Protocol.Relay` first. It answers `auth.refresh` itself and takes `auth` out of
  `initialize`, so no token reaches the laptop; the laptop answers everything else,
  checking again against its own record.

  A laptop that is not there is `unavailable` with `offline_since`, and nothing is held
  for it. A withdrawal, or a share that no longer names the person, ends the view with
  `relay.closed` and the reason.

  **A laptop that goes pauses the view.** The view stays open and is sent the ephemeral
  event `offer_paused {reason, since}` on the session's topic, `reason` being what the
  laptop's connection said as it went (`Troupe.Protocol.Relay.paused_reasons/0`); a request
  meanwhile is `unavailable` with `paused` and `Relay.paused_refusal/0`, and nothing is
  held for the laptop. When the laptop holds the session again the view is sent
  `offer_resumed` and ends with `relay.closed {reason: "the laptop is back"}`: the session's
  connection on the laptop went with the laptop, so the client opens the view again and
  subscribes from its own cursor, which loses nothing. A withdrawal while away ends it as
  any withdrawal does.
  """

  @behaviour WebSock

  alias Troupe.Plane.{Identity, Remote}
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Remote.Auth
  alias Troupe.Protocol.{Error, Event, JSONRPC, Relay}

  @back "the laptop is back"

  @renew_warning_seconds 120
  @expiry_grace_seconds 30

  @impl WebSock
  def init(opts) do
    {:ok,
     %{
       bearer: Keyword.get(opts, :bearer),
       id: nil,
       user: nil,
       session_id: nil,
       role: nil,
       laptop: nil,
       monitor: nil,
       timers: [],
       # Why the laptop is away, while the view waits for it.
       paused: nil,
       watching: false
     }}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case JSONRPC.decode(text) do
      {:ok, message} -> handle_message(message, text, state)
      {:error, error} -> {:push, frame({:error, nil, error}), state}
    end
  end

  def handle_in({_data, [opcode: _other]}, state), do: {:stop, :normal, 1003, state}

  defp handle_message({:request, id, "initialize", params}, _text, %{id: nil} = state) do
    token = get_in(params, ["auth", "token"]) || state.bearer

    with {:ok, user, claims} <- Auth.viewer(token),
         {:ok, offer, held} <- Remote.access(claims["session_id"], user),
         role when is_binary(role) <- Relay.narrower(claims["role"], held),
         {:ok, laptop} <- online(offer) do
      viewer = "v-" <> (12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
      person = %{"subject" => user.subject, "display_name" => user.display_name, "email" => user.email}

      state = %{
        state
        | id: viewer,
          user: user,
          session_id: offer.session_id,
          role: role,
          laptop: laptop,
          monitor: Process.monitor(laptop)
      }

      send(laptop, {:viewer_open, viewer, self(), offer.session_id, person, role})
      initialize = Map.delete(params, "auth")
      send(laptop, {:viewer_frame, viewer, JSONRPC.encode({:request, id, "initialize", initialize})})
      {:ok, expiry(state, claims["exp"])}
    else
      {:error, %Error{} = error} -> refuse(id, error, state)
      nil -> refuse(id, Error.new(:forbidden, %{reason: "not shared with you"}), state)
    end
  end

  defp handle_message({:request, id, _method, _params}, _text, %{id: nil} = state) do
    refuse(id, Error.new(:not_initialized), state)
  end

  # While the laptop is away nothing reaches it, and nothing is held for it: what was sent
  # is refused in words, and sent again once the laptop is back.
  defp handle_message({:request, id, method, _params}, _text, %{paused: reason} = state)
       when is_binary(reason) and method != "auth.refresh" do
    error = Error.new(:unavailable, %{paused: reason, reason: Relay.paused_refusal()})
    {:push, frame({:error, id, error}), state}
  end

  defp handle_message({:request, id, "auth.refresh", params}, _text, state) do
    with {:ok, user, claims} <- Auth.viewer(get_in(params, ["auth", "token"])),
         true <- user.subject == state.user.subject and claims["session_id"] == state.session_id,
         {:ok, _offer, held} <- Remote.access(state.session_id, user),
         role when is_binary(role) <- Relay.narrower(claims["role"], held) do
      state = expiry(%{state | user: user, role: role}, claims["exp"])

      result = %{
        "principal" => %{"subject" => user.subject, "display_name" => user.display_name},
        "scopes" => Enum.map(Relay.scopes(role), &Atom.to_string/1),
        "auth" => %{"expires_at" => claims["exp"]}
      }

      {:push, frame({:result, id, result}), state}
    else
      _refused -> refuse(id, Error.new(:unauthenticated, %{reason: "not this view's token"}), state)
    end
  end

  defp handle_message({:request, id, method, params}, text, state) do
    with :ok <- Relay.check(method, params, state.session_id, state.role),
         :ok <- still_shared(method, state) do
      send(state.laptop, {:viewer_frame, state.id, text})
      {:ok, state}
    else
      {:error, %Error{} = error} -> {:push, frame({:error, id, error}), state}
    end
  end

  # An answer or a notification: the protocol's own, relayed as it is.
  defp handle_message(_message, text, %{laptop: laptop} = state) when is_pid(laptop) do
    send(laptop, {:viewer_frame, state.id, text})
    {:ok, state}
  end

  defp handle_message(_message, _text, state), do: {:ok, state}

  # Steering is asked again of the row and of the account, so a share taken back or a
  # person deactivated stops steering at their next command rather than at their next
  # token. Reading needs no more than the view, which a withdrawal ends.
  defp still_shared(method, state) do
    if Map.get(Relay.methods(), method) == :control do
      with %User{active: true} = user <- Identity.get_user(state.user.subject),
           {:ok, _offer, held} <- Remote.access(state.session_id, user),
           "control" <- Relay.narrower(state.role, held) do
        :ok
      else
        _ -> {:error, Error.new(:forbidden, %{required_scope: "control", reason: "access changed"})}
      end
    else
      :ok
    end
  end

  @impl WebSock
  def handle_info({:relay_frame, data}, state), do: {:push, {:text, data}, state}

  def handle_info({:relay_closed, reason}, state), do: closed(reason, state)

  def handle_info({:recheck, offer}, state) do
    case Remote.role(offer, state.user) do
      nil -> closed(unshared(offer), state)
      held -> {:ok, %{state | role: Relay.narrower(state.role, held)}}
    end
  end

  # The laptop's connection went, saying why or not: the view waits for it.
  def handle_info({:laptop_paused, reason}, state), do: pause(state, reason)

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state),
    do: pause(state, "offline")

  # Something about offers changed: while the laptop is away, whether it is back, or the
  # offer gone.
  def handle_info({:remote_changed, _subjects}, %{paused: reason} = state) when is_binary(reason),
    do: back?(state)

  def handle_info({:remote_changed, _subjects}, state), do: {:ok, state}

  def handle_info(:auth_expiring, state) do
    payload = %{"expires_at" => Map.get(state, :expires_at)}
    {:push, frame({:notification, "auth.expiring", payload}), state}
  end

  def handle_info(:auth_expired, state), do: closed("the token expired", state)

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, %{laptop: laptop, id: id} = state) when is_pid(laptop) do
    send(laptop, {:viewer_gone, id})
    state
  end

  def terminate(_reason, state), do: state

  # Said once: a laptop already away that is heard going again (its connection's end and
  # the monitor both say it) is the same pause.
  defp pause(%{paused: reason} = state, _again) when is_binary(reason), do: {:ok, state}

  defp pause(state, reason) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    unless state.watching, do: Remote.subscribe()

    state = %{state | laptop: nil, monitor: nil, paused: reason, watching: true}
    since = DateTime.utc_now() |> DateTime.to_iso8601()

    # A laptop that dialled again before its old connection was seen to go is back already.
    case back?(state) do
      {:ok, state} -> {:push, offer_event(state, "offer_paused", %{"reason" => reason, "since" => since}), state}
      ended -> ended
    end
  end

  # Back: the view ends, saying so, for the client to open it again from its cursor; gone:
  # it ends as a withdrawal does; neither: it waits on.
  defp back?(state) do
    with %User{active: true} = user <- Identity.get_user(state.user.subject),
         {:ok, _offer, _held} <- Remote.access(state.session_id, user) do
      if Remote.laptop(state.session_id) do
        resumed = offer_event(state, "offer_resumed", %{})
        closing = frame({:notification, "relay.closed", %{"reason" => @back}})
        {:stop, :normal, 1000, [resumed, closing], state}
      else
        {:ok, state}
      end
    else
      _gone -> closed("withdrawn", state)
    end
  end

  defp offer_event(state, type, data) do
    event = type |> Event.ephemeral(nil, data) |> Event.to_json()
    params = %{"topic" => "session:" <> state.session_id, "session_id" => state.session_id, "event" => event}
    frame({:notification, "event", params})
  end

  defp closed(reason, state) do
    {:stop, :normal, 1000, [frame({:notification, "relay.closed", %{"reason" => reason}})], state}
  end

  # A private session's view ends because the invitation went; any other, because the
  # laptop's share no longer names the person.
  defp unshared(%Remote.Offer{private: true}), do: Relay.invitation_taken_back()
  defp unshared(_offer), do: "no longer shared with you"

  defp refuse(id, error, state), do: {:stop, :normal, 1000, [frame({:error, id, error})], state}

  # The laptop's connection, or `unavailable` saying since when it has been away.
  defp online(offer) do
    case Remote.laptop(offer.session_id) do
      nil ->
        {_state, since} = Remote.presence(offer)

        {:error,
         Error.new(:unavailable, %{
           reason: "the laptop is offline",
           offline_since: since && DateTime.to_iso8601(since)
         })}

      pid ->
        {:ok, pid}
    end
  end

  defp expiry(state, exp) when is_integer(exp) do
    Enum.each(state.timers, &Process.cancel_timer/1)
    now = System.system_time(:second)
    warn = max((exp - @renew_warning_seconds - now) * 1000, 0)
    hard = max((exp + @expiry_grace_seconds - now) * 1000, 0)

    state
    |> Map.put(:expires_at, exp)
    |> Map.put(:timers, [
      Process.send_after(self(), :auth_expiring, warn),
      Process.send_after(self(), :auth_expired, hard)
    ])
  end

  defp expiry(state, _exp), do: state

  defp frame(message), do: {:text, JSONRPC.encode(message)}
end
