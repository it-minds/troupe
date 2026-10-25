defmodule Troupe.Plane.Remote.Watch do
  @moduledoc """
  A person's watch on the laptop sessions offered to them: `GET /v1/relay/watch`.

  The desktop app and the console list what `remote.list` answers, and a list that is
  asked every few seconds is a poll. This socket is what they hold instead, one per
  signed-in client: it takes the person's ordinary plane token (the one `/rpc` takes) at
  `initialize`, answers with the person's whole list as `remote.list` would (`sessions`),
  and then sends `remote.changed {sessions}`, the whole list again, each time it changes:
  an offer made, shared anew or withdrawn, a laptop come or gone. A change elsewhere is
  never sent:
  the plane tells a watch only of changes that name its person
  (`Troupe.Plane.Remote.changed/1`), and the watch sends a list only where it differs from
  the last one it sent.

  The invitations to the person ride the same socket (#765): the answer carries them as
  `invites.list` would (`invites`), and `invites.changed {invites}`, the whole list again,
  follows each invitation to them made, changed or taken back
  (`Troupe.Plane.Invites.changed/1`). A client that does not know the notification ignores
  it.

  It carries nothing of a session, and asks nothing of a laptop: what it sends is the
  listing's metadata. It is renewed on the open socket (`auth.refresh`), warned two
  minutes before its token ends (`auth.expiring`), and closed with `auth.expired` after.
  A person deactivated is closed at the next change.
  """

  @behaviour WebSock

  alias Troupe.Plane.{Identity, Invites, Remote}
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Remote.Auth
  alias Troupe.Protocol.{Error, JSONRPC}

  @renew_warning_seconds 120
  @expiry_grace_seconds 30

  @impl WebSock
  def init(opts) do
    {:ok,
     %{
       bearer: Keyword.get(opts, :bearer),
       user: nil,
       sent: nil,
       invites: nil,
       timers: [],
       expires_at: nil
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

  defp handle_message({:request, id, "initialize", params}, %{user: nil} = state) do
    with {:ok, user, claims} <- Auth.person(get_in(params, ["auth", "token"]) || state.bearer),
         :ok <- Remote.subscribe(),
         :ok <- Invites.subscribe() do
      rows = Remote.rows(user)
      invites = Invites.to(user)
      state = expiry(%{state | user: user, sent: rows, invites: invites}, claims["exp"])

      # The list as it stands is in the answer, and only a change follows it: a list sent
      # in the same breath as the answer can wait in a client's buffer for its next read.
      result = %{
        "protocol_version" => Troupe.Protocol.version(),
        "server_info" => %{"name" => "troupe-plane", "watch" => "remote"},
        "principal" => %{"subject" => user.subject, "display_name" => user.display_name},
        "scopes" => [],
        "capabilities" => %{"remote_changed" => true, "invites_changed" => true},
        "auth" => %{"expires_at" => claims["exp"]},
        "sessions" => rows,
        "invites" => invites
      }

      {:push, frame({:result, id, result}), state}
    else
      {:error, %Error{} = error} -> refuse(id, error, state)
      {:error, reason} -> refuse(id, Error.new(:unavailable, %{reason: inspect(reason)}), state)
    end
  end

  defp handle_message({:request, id, _method, _params}, %{user: nil} = state) do
    refuse(id, Error.new(:not_initialized), state)
  end

  defp handle_message({:request, id, "auth.refresh", params}, state) do
    with {:ok, user, claims} <- Auth.person(get_in(params, ["auth", "token"])),
         true <- user.subject == state.user.subject do
      state = expiry(%{state | user: user}, claims["exp"])
      {:push, frame({:result, id, %{"auth" => %{"expires_at" => claims["exp"]}}}), state}
    else
      _refused ->
        refuse(id, Error.new(:unauthenticated, %{reason: "not this watch's person"}), state)
    end
  end

  # The list again, for a client that wants to be sure rather than wait for a change.
  defp handle_message({:request, id, "remote.list", _params}, state) do
    rows = Remote.rows(state.user)
    {:push, frame({:result, id, %{"sessions" => rows}}), %{state | sent: rows}}
  end

  defp handle_message({:request, id, "invites.list", _params}, state) do
    invites = Invites.to(state.user)
    {:push, frame({:result, id, %{"invites" => invites}}), %{state | invites: invites}}
  end

  defp handle_message({:request, id, method, _params}, state) do
    {:push, frame({:error, id, Error.new(:method_not_found, %{method: method})}), state}
  end

  defp handle_message(_notification_or_answer, state), do: {:ok, state}

  @impl WebSock
  def handle_info({:remote_changed, subjects}, %{user: %User{subject: subject}} = state) do
    if subject in subjects, do: tell(Identity.get_user(subject), state), else: {:ok, state}
  end

  def handle_info({:invites_changed, subjects}, %{user: %User{subject: subject}} = state) do
    if subject in subjects,
      do: tell_invites(Identity.get_user(subject), state),
      else: {:ok, state}
  end

  def handle_info(:auth_expiring, state) do
    {:push, frame({:notification, "auth.expiring", %{"expires_at" => state.expires_at}}), state}
  end

  def handle_info(:auth_expired, state) do
    {:stop, :normal, 1000, [frame({:notification, "auth.expired", %{}})], state}
  end

  def handle_info(_message, state), do: {:ok, state}

  # A change that names the person: their list again, if it moved, or the end of the watch
  # for a person no longer active.
  defp tell(%User{active: true} = user, state) do
    case list(%{state | user: user}) do
      {[], state} -> {:ok, state}
      {changed, state} -> {:push, changed, state}
    end
  end

  defp tell(_gone, state) do
    {:stop, :normal, 1000,
     [frame({:notification, "auth.expired", %{"reason" => "account deactivated"}})], state}
  end

  # The invitations to the person, as a frame where they differ from the last ones sent.
  defp tell_invites(%User{active: true} = user, state) do
    invites = Invites.to(user)

    if invites == state.invites,
      do: {:ok, state},
      else:
        {:push, [frame({:notification, "invites.changed", %{"invites" => invites}})],
         %{state | user: user, invites: invites}}
  end

  defp tell_invites(gone, state), do: tell(gone, state)

  # The person's list, as a frame where it differs from the last one sent.
  defp list(state) do
    rows = Remote.rows(state.user)

    if rows == state.sent,
      do: {[], state},
      else:
        {[frame({:notification, "remote.changed", %{"sessions" => rows}})], %{state | sent: rows}}
  end

  defp refuse(id, error, state), do: {:stop, :normal, 1000, [frame({:error, id, error})], state}

  defp expiry(state, exp) when is_integer(exp) do
    Enum.each(state.timers, &Process.cancel_timer/1)
    now = System.system_time(:second)
    warn = max((exp - @renew_warning_seconds - now) * 1000, 0)
    hard = max((exp + @expiry_grace_seconds - now) * 1000, 0)

    %{
      state
      | expires_at: exp,
        timers: [
          Process.send_after(self(), :auth_expiring, warn),
          Process.send_after(self(), :auth_expired, hard)
        ]
    }
  end

  defp expiry(state, _exp), do: state

  defp frame(message), do: {:text, JSONRPC.encode(message)}
end
