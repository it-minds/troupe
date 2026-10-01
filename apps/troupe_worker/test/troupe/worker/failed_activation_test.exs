defmodule Troupe.Worker.FailedActivationTest do
  @moduledoc """
  An activation that fails takes away what it put on the pod, and nothing else.

  A restore writes the session's log into the pod's state directory and then puts the
  tree back beside it, both in plaintext. An activation that failed after the log was
  written left both there until the session was next activated on this pod or went
  dormant here, which for a session that goes on to run on another pod is never. These
  pin that a failure after the events were restored leaves neither the log nor the tree,
  however it failed, and that what the activation found on the pod before it started —
  the encrypted cache, a reader's log, a tree — is left as it was.
  """

  use Troupe.Worker.SessionCase, async: false

  import ExUnit.CaptureLog

  alias Troupe.Worker.Cache
  alias Troupe.Worker.RecordingProxy
  alias Troupe.Worker.Session.{Reader, Restore}

  @moduletag timeout: 120_000

  test "a failure after the events were restored leaves neither the log nor a tree", context do
    context = requires_tier(context)
    cached = a_dormant_session(context)

    # Storage answers for the events and then not for the tree.
    proxy = start_supervised!(relay(context, drop: listing_of(context.session_id, "workspace/")))

    assert {:error, {:object_store_unreachable, _endpoint, _reason}} =
             activate(through(context, proxy), epoch: 2)

    assert RecordingProxy.captured(proxy) =~ listing_of(context.session_id, "segments/")

    refute File.exists?(log_dir(context))
    refute File.exists?(context.workspace)
    assert Cache.get_workspace(context.session_id, context.state_dir) == cached
  end

  test "a failure once the tree is back leaves neither the log nor the tree", context do
    context = requires_tier(context)
    cached = a_dormant_session(context)

    # A provider no build has: the log and the tree are put back, and then the session
    # does not start.
    assert {:error, _reason} =
             activate(context, epoch: 2, config_overrides: [provider: "no-such-provider"])

    refute File.exists?(log_dir(context))
    refute File.exists?(context.workspace)
    assert Cache.get_workspace(context.session_id, context.state_dir) == cached
  end

  test "a failure that raises on the way is cleaned up the same way", context do
    context = requires_tier(context)
    cached = a_dormant_session(context)

    # A file where the tree goes, so putting the tree back raises after the log is written.
    File.write!(context.workspace, "not a directory")

    capture_log(fn ->
      assert {:error, {:activation_failed, _reason}} = activate(context, epoch: 2)
    end)

    refute File.exists?(log_dir(context))
    assert File.read!(context.workspace) == "not a directory"
    assert Cache.get_workspace(context.session_id, context.state_dir) == cached
  end

  test "what the activation found on the pod is left as it was, whether it failed before the events or after",
       context do
    context = requires_tier(context)
    cached = a_dormant_session(context)

    # Somebody is reading the dormant session here, so its reader has restored the log; and
    # a run this pod did not put to sleep left a tree.
    assert {:ok, %{source: :storage}} = Reader.open(context.session_id, reading(context))
    log = File.read!(Restore.log_path(context.session_id, context.workspace, context.state_dir))
    history = Troupe.replay_from(context.session_id, 0)
    assert history != []

    File.mkdir_p!(context.workspace)
    File.write!(Path.join(context.workspace, "left.md"), "by a run nobody put to sleep")

    # Before the events: a key manager the pod cannot reach.
    capture_log(fn ->
      assert {:error, {:kms_unreachable, _address, _reason}} =
               Sessions.activate(
                 context.session_id,
                 activation(context, epoch: 2) ++ [kms_options: [address: "http://127.0.0.1:1"]]
               )
    end)

    assert_left_as_it_was(context, log, history, cached)

    # After the events: storage stops answering at the tree.
    proxy = start_supervised!(relay(context, drop: listing_of(context.session_id, "workspace/")))

    assert {:error, {:object_store_unreachable, _endpoint, _reason}} =
             activate(through(context, proxy), epoch: 2)

    assert_left_as_it_was(context, log, history, cached)
  end

  test "a log a reader was writing as the activation started is found, and left", context do
    context = requires_tier(context)
    cached = a_dormant_session(context)
    test = self()

    # A reader that has looked for a manager under the lock and found none, and writes the
    # log before it lets go.
    reader =
      spawn(fn ->
        Restore.with_log(context.session_id, fn ->
          send(test, :holding)

          receive do
            :write ->
              File.mkdir_p!(log_dir(context))
              File.write!(Path.join(log_dir(context), "events.jsonl"), "the reader's\n")
          end
        end)
      end)

    assert_receive :holding

    # An activation registers meanwhile, and fails at the tree once it has put the events
    # back.
    proxy = start_supervised!(relay(context, drop: listing_of(context.session_id, "workspace/")))
    options = activation(through(context, proxy), epoch: 2)
    activating = Task.async(fn -> Sessions.activate(context.session_id, options) end)
    manager = eventually(fn -> Sessions.whereis(context.session_id) end)
    eventually(fn -> waiting_for_the_log?(manager) end)

    send(reader, :write)

    assert {:error, {:object_store_unreachable, _endpoint, _reason}} =
             Task.await(activating, 60_000)

    assert File.exists?(log_dir(context))
    assert Cache.get_workspace(context.session_id, context.state_dir) == cached
  end

  # Waiting for `Restore.with_log/2`'s lock, which nobody holding it is.
  defp waiting_for_the_log?(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, stack} -> Enum.any?(stack, &match?({:global, :set_lock, _, _}, &1))
      nil -> false
    end
  end

  defp assert_left_as_it_was(context, log, history, cached) do
    path = Restore.log_path(context.session_id, context.workspace, context.state_dir)
    assert File.read!(path) == log
    assert Troupe.replay_from(context.session_id, 0) == history

    assert File.read!(Path.join(context.workspace, "left.md")) == "by a run nobody put to sleep"
    assert Cache.get_workspace(context.session_id, context.state_dir) == cached
  end

  # A session that ran on this pod and went to sleep here: its tree archived to storage and
  # cached on the pod, sealed, and the log and the tree gone from the pod.
  defp a_dormant_session(context) do
    assert {:ok, _} = activate(context)
    File.write!(Path.join(context.workspace, "notes.md"), "as this pod left it")
    assert {:ok, _} = Sessions.dormant(context.session_id)

    refute File.exists?(log_dir(context))
    refute File.exists?(context.workspace)

    cached = Cache.get_workspace(context.session_id, context.state_dir)
    assert {:ok, _seq, _sealed} = cached
    cached
  end

  defp log_dir(context) do
    Path.dirname(Restore.log_path(context.session_id, context.workspace, context.state_dir))
  end

  defp reading(context) do
    [
      team: context.team,
      epoch: 1,
      store: context.store,
      state_dir: context.state_dir,
      workspace: context.workspace
    ]
  end

  # A relay to the same store that closes the connection of a request carrying `drop`.
  defp relay(context, drop: drop) do
    {RecordingProxy, upstream: URI.parse(context.store.endpoint).port, drop: drop}
  end

  defp through(context, proxy) do
    endpoint = "http://127.0.0.1:#{RecordingProxy.port(proxy)}"
    %{context | store: %{context.store | endpoint: endpoint}}
  end

  # The request line of a listing under the session's prefix, as
  # `Troupe.ObjectStore.list/2` encodes it.
  defp listing_of(session_id, under) do
    "prefix=" <> URI.encode_www_form(Storage.prefix(session_id) <> under)
  end
end
