defmodule Troupe.Plane.Remote.Laptop do
  @moduledoc """
  A laptop's one connection to the plane while it offers sessions: `GET /v1/relay`.

  The daemon dials it with its person's plane token (in `Authorization`, or `auth.token`
  on `initialize`), says what it offers (`relay.sync`, then `relay.offer` and
  `relay.withdraw` as its person changes that), renews the token on the open socket
  (`auth.refresh`), and the plane relays each remote person to it: `relay.open` names the
  viewer, the person and the role, `relay.frame` carries one protocol message either way,
  and `relay.close` ends one view. A token is never relayed: the plane answers a viewer's
  `auth.refresh` itself and strips `auth` from its `initialize`.

  The connection holds a `:global` name per session it offers, which is what a viewer on
  any replica finds it by and what "online" means. It is closed at its token's expiry if
  it was not renewed, and every view it carried ends with it.

  Each change it makes is told to the people it concerns (`Troupe.Plane.Remote.changed/1`)
  once it is in force, the row written and the names held or let go, so a person's watch
  (`Troupe.Plane.Remote.Watch`) that reads again reads what is now true.

  Each offer is recorded in the audit trail as `remote.offer`, with the device, how many
  people it is shared with and whether the session is private. What a session says is not
  there, nor anywhere else on the plane: the frames pass through this process and nothing
  of them is written.
  """

  @behaviour WebSock

  alias Troupe.Plane.{Audit, Remote}
  alias Troupe.Plane.Remote.Auth
  alias Troupe.Protocol.{Error, JSONRPC, Relay}

  @renew_warning_seconds 120
  @expiry_grace_seconds 30

  @impl WebSock
  def init(opts) do
    {:ok,
     %{
       bearer: Keyword.get(opts, :bearer),
       user: nil,
       device: nil,
       sessions: MapSet.new(),
       viewers: %{},
       timers: []
     }}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case JSONRPC.decode(text) do
      {:ok, message} -> handle_message(message, state)
      {:error, error} -> {:push, frame({:error, nil, error}), state}
    end
  end

  def handle_in({_data, [opcode: _other]}, state), do: {:stop, :normal, 1003, state}

  # -- from the laptop --------------------------------------------------------

  defp handle_message({:request, id, "initialize", params}, %{user: nil} = state) do
    token = get_in(params, ["auth", "token"]) || state.bearer
    device = get_in(params, ["capabilities", "device"])

    with {:ok, device} <- device(device),
         {:ok, user, claims} <- Auth.laptop(token, device) do
      state = expiry(%{state | user: user, device: device}, claims["exp"])

      result = %{
        "protocol_version" => Troupe.Protocol.version(),
        "server_info" => %{"name" => "troupe-plane", "relay" => true},
        "principal" => %{"subject" => user.subject, "display_name" => user.display_name},
        "scopes" => [],
        "auth" => %{"expires_at" => claims["exp"]}
      }

      {:push, frame({:result, id, result}), state}
    else
      {:error, %Error{} = error} -> {:stop, :normal, 1000, [frame({:error, id, error})], state}
    end
  end

  defp handle_message({:request, id, _method, _params}, %{user: nil} = state) do
    {:stop, :normal, 1000, [frame({:error, id, Error.new(:not_initialized)})], state}
  end

  defp handle_message({:request, id, "auth.refresh", params}, state) do
    with {:ok, user, claims} <- Auth.laptop(get_in(params, ["auth", "token"]), state.device),
         true <- user.subject == state.user.subject do
      state = expiry(%{state | user: user}, claims["exp"])
      {:push, frame({:result, id, %{"auth" => %{"expires_at" => claims["exp"]}}}), state}
    else
      _refused ->
        error = Error.new(:unauthenticated, %{reason: "not this connection's person"})
        {:stop, :normal, 1000, [frame({:error, id, error})], state}
    end
  end

  defp handle_message({:request, id, "relay.sync", params}, state) do
    offers = if is_list(params["offers"]), do: params["offers"], else: []
    before = Remote.offers_from(state.user, state.device)
    {kept, refused} = Remote.sync(state.user, state.device, offers)
    kept_ids = MapSet.new(kept, & &1.session_id)

    # What the laptop no longer offers stops being found here, and its views end.
    state =
      state.sessions
      |> MapSet.difference(kept_ids)
      |> Enum.reduce(state, &stop_offering(&2, &1, "withdrawn"))

    state = Enum.reduce(kept, state, &hold(&2, &1))
    Remote.changed(Enum.flat_map(before ++ kept, &Remote.concerned/1))

    result = %{
      "offers" =>
        Enum.map(kept, &%{"session_id" => &1.session_id, "shares" => Remote.Offer.people(&1)}),
      "refused" =>
        Enum.map(refused, fn {session_id, error} ->
          %{"session_id" => session_id, "error" => JSONRPC.to_map({:error, nil, error})["error"]}
        end)
    }

    {:push, frame({:result, id, result}), state}
  end

  defp handle_message({:request, id, "relay.offer", params}, state) do
    before = Remote.get(params["session_id"])

    case Remote.offer(state.user, state.device, params) do
      {:ok, offer} ->
        state = state |> hold(offer) |> recheck(offer)
        audit_offer(state, offer)
        # Everybody it was shared with before and is now: one it no longer names loses it.
        Remote.changed(Remote.concerned(before) ++ Remote.concerned(offer))
        {:push, frame({:result, id, %{"shares" => Remote.Offer.people(offer)}}), state}

      {:error, error} ->
        {:push, frame({:error, id, error}), state}
    end
  end

  defp handle_message({:request, id, "relay.withdraw", params}, state) do
    session_id = params["session_id"]

    if is_binary(session_id) do
      before = Remote.get(session_id)
      :ok = Remote.withdraw(state.user, session_id)
      state = stop_offering(state, session_id, withdrawn(before))

      if before && before.owner_subject == state.user.subject,
        do: Remote.changed(Remote.concerned(before))
      {:push, frame({:result, id, %{"withdrawn" => true}}), state}
    else
      {:push, frame({:error, id, Error.new(:invalid_params, %{field: "session_id"})}), state}
    end
  end

  defp handle_message({:request, id, method, _params}, state) do
    {:push, frame({:error, id, Error.new(:method_not_found, %{method: method})}), state}
  end

  defp handle_message({:notification, "relay.frame", %{"viewer" => id, "data" => data}}, state)
       when is_binary(data) do
    case Map.fetch(state.viewers, id) do
      {:ok, viewer} -> send(viewer.pid, {:relay_frame, data})
      :error -> :ok
    end

    {:ok, state}
  end

  defp handle_message({:notification, "relay.close", %{"viewer" => id} = params}, state) do
    case Map.pop(state.viewers, id) do
      {nil, _viewers} ->
        {:ok, state}

      {viewer, viewers} ->
        Process.demonitor(viewer.monitor, [:flush])
        send(viewer.pid, {:relay_closed, params["reason"] || "the laptop closed the view"})
        {:ok, %{state | viewers: viewers}}
    end
  end

  defp handle_message(_other, state), do: {:ok, state}

  # -- from viewers -----------------------------------------------------------

  @impl WebSock
  def handle_info({:viewer_open, id, pid, session_id, person, role}, state) do
    if MapSet.member?(state.sessions, session_id) do
      monitor = Process.monitor(pid)
      viewer = %{pid: pid, monitor: monitor, session_id: session_id}
      params = %{"viewer" => id, "session_id" => session_id, "person" => person, "role" => role}

      {:push, frame({:notification, "relay.open", params}),
       %{state | viewers: Map.put(state.viewers, id, viewer)}}
    else
      send(pid, {:relay_closed, "the session is not offered"})
      {:ok, state}
    end
  end

  def handle_info({:viewer_frame, id, data}, state) do
    if Map.has_key?(state.viewers, id),
      do: {:push, frame({:notification, "relay.frame", %{"viewer" => id, "data" => data}}), state},
      else: {:ok, state}
  end

  def handle_info({:viewer_gone, id}, state), do: forget_viewer(state, id)

  # An invitation into a session this connection offers was made, changed or taken back:
  # the views open on it meet it now, and one whose person no longer holds a role ends.
  def handle_info({:offer_changed, session_id}, state) do
    case Remote.get(session_id) do
      %Remote.Offer{} = offer ->
        if MapSet.member?(state.sessions, session_id), do: recheck(state, offer)
        {:ok, state}

      nil ->
        {:ok, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Enum.find(state.viewers, fn {_id, v} -> v.pid == pid end) do
      nil -> {:ok, state}
      {id, _viewer} -> forget_viewer(state, id)
    end
  end

  def handle_info(:auth_expiring, state) do
    {:push, frame({:notification, "auth.expiring", %{}}), state}
  end

  def handle_info(:auth_expired, state) do
    {:stop, :normal, 1000, [frame({:notification, "auth.expired", %{}})], state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, %{user: %{subject: subject}} = state) do
    Enum.each(state.viewers, fn {_id, viewer} ->
      send(viewer.pid, {:relay_closed, "the laptop went offline"})
    end)

    # Let go of the names before saying so: a watch that reads again as it hears it
    # must find the laptop gone, and a dying process would hold them a moment longer.
    Enum.each(state.sessions, fn session_id ->
      if :global.whereis_name(Remote.name(session_id)) == self(),
        do: :global.unregister_name(Remote.name(session_id))
    end)

    Remote.offline(subject, state.device, MapSet.to_list(state.sessions))

    state.user
    |> Remote.offers_from(state.device)
    |> Enum.filter(&MapSet.member?(state.sessions, &1.session_id))
    |> Enum.flat_map(&Remote.concerned/1)
    |> Remote.changed()

    state
  end

  def terminate(_reason, state), do: state

  # -- holding names ----------------------------------------------------------

  # The newest connection of the laptop is the one that holds the name: a laptop that
  # dialled again before the plane saw its old connection go is still the same laptop,
  # and the row says it is this person's.
  defp hold(state, offer) do
    name = Remote.name(offer.session_id)

    case :global.whereis_name(name) do
      pid when pid == self() -> :ok
      :undefined -> :global.register_name(name, self())
      _other -> :global.re_register_name(name, self())
    end

    %{state | sessions: MapSet.put(state.sessions, offer.session_id)}
  end

  defp stop_offering(state, session_id, reason) do
    if :global.whereis_name(Remote.name(session_id)) == self(),
      do: :global.unregister_name(Remote.name(session_id))

    {closing, kept} = Enum.split_with(state.viewers, fn {_id, v} -> v.session_id == session_id end)

    Enum.each(closing, fn {_id, viewer} ->
      Process.demonitor(viewer.monitor, [:flush])
      send(viewer.pid, {:relay_closed, reason})
    end)

    %{state | sessions: MapSet.delete(state.sessions, session_id), viewers: Map.new(kept)}
  end

  # A share made again reaches the views already open: one whose person it no longer
  # names ends, the laptop's own check holding the rest to the new role.
  defp recheck(state, offer) do
    Enum.each(state.viewers, fn {_id, viewer} ->
      if viewer.session_id == offer.session_id, do: send(viewer.pid, {:recheck, offer})
    end)

    state
  end

  # Who offered what, from where, to how many, and whether it is private: never a word of
  # what the session says.
  defp audit_offer(state, offer) do
    {:ok, _} =
      Audit.record(state.user.subject, "remote.offer", offer.session_id, %{
        "device" => state.device,
        "private" => offer.private == true,
        "shared_with" => length(Remote.Offer.people(offer))
      })

    :ok
  end

  defp withdrawn(%Remote.Offer{private: true}), do: Relay.private_withdrawn()
  defp withdrawn(_offer), do: "withdrawn"

  defp forget_viewer(state, id) do
    case Map.pop(state.viewers, id) do
      {nil, _viewers} ->
        {:ok, state}

      {viewer, viewers} ->
        Process.demonitor(viewer.monitor, [:flush])

        {:push, frame({:notification, "relay.close", %{"viewer" => id, "reason" => "the person left"}}),
         %{state | viewers: viewers}}
    end
  end

  defp device(device) when is_binary(device) and byte_size(device) in 1..128, do: {:ok, device}

  defp device(_device),
    do: {:error, Error.new(:invalid_params, %{field: "capabilities.device", reason: "a laptop names its device"})}

  defp expiry(state, exp) when is_integer(exp) do
    Enum.each(state.timers, &Process.cancel_timer/1)
    now = System.system_time(:second)
    warn = max((exp - @renew_warning_seconds - now) * 1000, 0)
    hard = max((exp + @expiry_grace_seconds - now) * 1000, 0)

    %{
      state
      | timers: [
          Process.send_after(self(), :auth_expiring, warn),
          Process.send_after(self(), :auth_expired, hard)
        ]
    }
  end

  defp expiry(state, _exp), do: state

  defp frame(message), do: {:text, JSONRPC.encode(message)}
end
