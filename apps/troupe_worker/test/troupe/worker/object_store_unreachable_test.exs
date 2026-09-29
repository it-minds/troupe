defmodule Troupe.Worker.ObjectStoreUnreachableTest do
  @moduledoc """
  A pod that cannot reach its object store says so, by name.

  Behind an egress policy that dropped the connection, every activation failed with an
  inspected `%Req.TransportError{reason: :timeout}`, in the pod's log and in what the plane
  relayed to the person: nothing said which host, or that it was storage at all. These pin
  the name, the endpoint beside it, and that it is still a failure the plane retries
  rather than one that parks the session.
  """

  use Troupe.Worker.SessionCase, async: false

  import ExUnit.CaptureLog

  alias Troupe.Protocol.Error
  alias Troupe.Worker.Plane.Commands
  alias Troupe.Worker.Session.Restore

  # Nothing listens on port 1, so the connection is refused at once: the failure a policy
  # that drops the connection makes, without waiting out a connect timeout for it.
  @endpoint "http://127.0.0.1:1"

  @moduletag timeout: 60_000

  test "an activation whose object store does not answer is refused as object_store_unreachable",
       context do
    context = requires_tier(context)
    unreachable = %{context.store | endpoint: @endpoint}

    log =
      capture_log(fn ->
        assert {:error, {:object_store_unreachable, @endpoint, :econnrefused}} =
                 activate(%{context | store: unreachable})
      end)

    assert log =~ "could not activate #{context.session_id}"
    assert log =~ "object_store_unreachable"
    assert log =~ @endpoint

    # What the plane is answered, and relays to whoever asked for the session.
    reason = {:object_store_unreachable, @endpoint, :econnrefused}

    assert %Error{
             message: "unavailable",
             data: %{
               reason: "object_store_unreachable",
               endpoint: @endpoint,
               detail: ":econnrefused"
             }
           } = Commands.activation_error(reason)

    # And no `session.unrestorable`: the session is intact where it is, and parking it
    # read-only over an outage would be the wrong answer (Decision 661).
    assert Manager.unrestorable_report(context.session_id, reason) == nil
  end

  test "reading the log names the store the same way" do
    context = %Context{
      session_id: Troupe.Session.generate_id(),
      team: "team-unreachable",
      epoch: 1,
      data_key: :crypto.strong_rand_bytes(32),
      store: unreachable_store()
    }

    root =
      Path.join(System.tmp_dir!(), "troupe-unreachable-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, {:object_store_unreachable, @endpoint, :econnrefused}} =
             Restore.events(context, root)
  end

  test "a timeout, and a segment read that timed out, are the same failure; anything else is left alone" do
    store = unreachable_store()
    timeout = %Req.TransportError{reason: :timeout}

    assert Restore.unreachable(store, timeout) == {:object_store_unreachable, @endpoint, :timeout}

    assert Restore.unreachable(
             store,
             {:unreadable_segment, "sessions/s/segments/1-1-2.seg", timeout}
           ) ==
             {:object_store_unreachable, @endpoint, :timeout}

    # A store that answered and refused, or a segment that will not decrypt, is not the
    # network, and naming it so would send an operator to the wrong place.
    assert Restore.unreachable(store, {:unexpected_status, 403, "denied"}) ==
             {:unexpected_status, 403, "denied"}

    assert Restore.unreachable(store, {:unreadable_segment, "k", :decrypt_failed}) ==
             {:unreadable_segment, "k", :decrypt_failed}
  end

  test "the enrolment check says in the log that the store does not answer, and is quiet when it does",
       context do
    log =
      capture_log(fn ->
        assert {:error, {:object_store_unreachable, @endpoint, :econnrefused}} =
                 Restore.check_reachable(unreachable_store())
      end)

    assert log =~ "this pod cannot use its object store"
    assert log =~ @endpoint

    context = requires_tier(context)
    log = capture_log(fn -> assert :ok = Restore.check_reachable(context.store) end)
    refute log =~ "cannot use its object store"
  end

  defp unreachable_store do
    %ObjectStore{
      endpoint: @endpoint,
      bucket: "troupe-sessions",
      access_key_id: "unused",
      secret_access_key: "unused"
    }
  end
end
