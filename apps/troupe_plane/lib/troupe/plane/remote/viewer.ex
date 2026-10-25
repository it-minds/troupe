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
  for it. A laptop that goes, a withdrawal, or a share that no longer names the person
  ends the view with `relay.closed` and the reason.
  """

  @behaviour WebSock

  alias Troupe.Plane.{Identity, Remote}
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Remote.Auth
  alias Troupe.Protocol.{Error, JSONRPC, Relay}

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
       timers: []
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

  defp handle_message({:request, id, "initialize", params}, _text, %{laptop: nil} = state) do
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

  defp handle_message({:request, id, _method, _params}, _text, %{laptop: nil} = state) do
    refuse(id, Error.new(:not_initialized), state)
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

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state) do
    closed("the laptop went offline", %{state | laptop: nil})
  end

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
