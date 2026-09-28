defmodule Troupe.Worker.KmsUnreachableTest do
  @moduledoc """
  A pod that cannot reach its key manager says so, by name.

  Opening a session's context is the first thing an activation does, and it asks the key
  manager for the session's data key. An OpenBao the pod could not reach failed that with
  the bare transport error, in the pod's log and in what the plane relayed: the same
  nothing #249 found for an object store, which says neither which host nor that it was
  the key manager. These pin the name, the address beside it, and that it is a failure the
  plane retries rather than one that parks the session.
  """

  use Troupe.Worker.SessionCase, async: false

  import ExUnit.CaptureLog

  alias Troupe.Worker.Plane.Commands

  # Nothing listens on port 1, so the connection is refused at once: the failure a policy
  # that drops the connection makes, without waiting out a connect timeout for it.
  @address "http://127.0.0.1:1"

  @moduletag timeout: 60_000

  test "an activation whose key manager does not answer is refused as kms_unreachable", context do
    context = requires_tier(context)

    Application.put_env(
      :troupe_worker,
      :session_defaults,
      activation(context) ++ [kms_options: [address: @address]]
    )

    on_exit(fn -> Application.delete_env(:troupe_worker, :session_defaults) end)

    params = %{"session_id" => context.session_id, "team" => context.team, "epoch" => 1}

    log =
      capture_log(fn ->
        # What the plane is answered, and relays to whoever asked for the session.
        assert {:error, error} = Commands.handle("session.activate", params)

        assert error.message == "unavailable"

        assert error.data == %{
                 reason: "kms_unreachable",
                 address: @address,
                 detail: ":econnrefused"
               }
      end)

    assert log =~ "could not activate #{context.session_id}"
    assert log =~ "kms_unreachable"
    assert log =~ @address

    assert Sessions.whereis(context.session_id) == nil

    # And no `session.unrestorable`: the session is intact, and parking it read-only over
    # an outage would be the wrong answer (Decision 661).
    reason = {:kms_unreachable, @address, :econnrefused}
    assert Manager.unrestorable_report(context.session_id, reason) == nil
  end

  test "a key manager that answers and refuses is not named unreachable", context do
    context = requires_tier(context)

    # A token OpenBao does not know: it answers, with a 403, which is not the network's
    # failure and would send an operator to the wrong place if it were called one.
    opts = activation(context) ++ [kms_options: [token: "not-a-token"]]

    capture_log(fn ->
      assert {:error, :forbidden} = Sessions.activate(context.session_id, opts)
    end)
  end
end
