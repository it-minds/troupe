defmodule Troupe.Worker.DormancyTest do
  @moduledoc """
  Going to sleep, waking up somewhere else, and being told you are the ghost.

  Three properties, and all three are about what is *not* there afterwards: no plaintext
  on the PVC once a session is dormant, no second tree when two clients activate at
  once, and nothing written by a pod whose epoch has moved on.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.LLM.Fake
  alias Troupe.Worker.Session.Restore

  @moduletag timeout: 180_000

  describe "dormancy" do
    test "leaves no plaintext workspace and no plaintext log behind", context do
      context = requires_tier(context)
      assert {:ok, _} = activate(context, report: reporter_to(self()))

      File.write!(Path.join(context.workspace, "notes.md"), "the secret plan")
      run_turn(context.session_id, "hello")

      log_dir =
        Path.dirname(Restore.log_path(context.session_id, context.workspace, context.state_dir))
      assert File.exists?(Path.join(log_dir, "events.jsonl"))

      assert {:ok, result} = Sessions.dormant(context.session_id)
      assert result.erased.workspace == :ok
      assert result.erased.log

      # The Forbidden list's first item, checked rather than assumed.
      refute File.exists?(context.workspace)
      refute File.exists?(log_dir)
      refute grep_plaintext(context.base, "the secret plan")
    end

    test "reports a sealed head the plane can anchor", context do
      context = requires_tier(context)
      assert {:ok, _} = activate(context, report: reporter_to(self()))

      run_turn(context.session_id, "hello")
      assert {:ok, result} = Sessions.dormant(context.session_id)

      report = await_dormant()
      assert report["session_id"] == context.session_id
      assert report["epoch"] == 1
      assert report["last_seq"] == result.sealed_through
      assert report["head_hash"] == result.head_hash

      # The head the plane was told about is the head object storage actually has.
      {:ok, manifest} = Storage.get_manifest(context.store, context.session_id)
      assert manifest["last_seq"] == report["last_seq"]
      assert manifest["head_hash"] == report["head_hash"]
    end

    test "costs no process once it has happened", context do
      context = requires_tier(context)
      assert {:ok, _} = activate(context)

      assert Sessions.active_count() == 1
      assert {:ok, _} = Sessions.dormant(context.session_id)

      assert Sessions.whereis(context.session_id) == nil
      assert Sessions.active_count() == 0
      assert Sessions.active_ids() == []
    end

    test "happens on its own once a session has been quiet long enough", context do
      context = requires_tier(context)
      assert {:ok, _} = activate(context, dormant_after_ms: 300, report: reporter_to(self()))

      report = await_dormant()
      assert report["reason"] == "dormant"
      eventually(fn -> Sessions.whereis(context.session_id) == nil end)
      refute File.exists?(context.workspace)
    end
  end

  describe "activation" do
    test "brings a session back on another pod with the same chain and head", context do
      context = requires_tier(context)
      assert {:ok, _} = activate(context, report: reporter_to(self()))

      run_turn(context.session_id, "remember this")
      assert {:ok, sealed} = Sessions.dormant(context.session_id)

      # A different pod: a different workspace path and a different state directory,
      # sharing nothing but object storage and the key store.
      elsewhere = Path.join(context.base, "pod-two")

      assert {:ok, _} =
               activate(context,
                 workspace: Path.join(elsewhere, "workspace"),
                 state_dir: Path.join(elsewhere, "state"),
                 epoch: 2
               )

      replayed = Troupe.replay_from(context.session_id, 0)
      assert Enum.any?(replayed, &(&1.type == "user_input"))
      assert Enum.any?(replayed, &(&1.type == "session_activated"))

      # Everything that was sealed is back, in order, and the chain over it holds.
      restored_head = Enum.find(replayed, &(&1.seq == sealed.sealed_through))
      assert Event.hash(restored_head) == sealed.head_hash
      assert :ok = Event.verify(Enum.filter(replayed, &(&1.seq <= sealed.sealed_through)))
    end

    test "brings the workspace back with it", context do
      context = requires_tier(context)
      assert {:ok, _} = activate(context)

      File.mkdir_p!(Path.join(context.workspace, "lib/deep"))
      File.write!(Path.join(context.workspace, "lib/deep/thing.ex"), "defmodule Thing do end")
      File.write!(Path.join(context.workspace, "README.md"), "# hello")
      File.chmod!(Path.join(context.workspace, "README.md"), 0o640)

      assert {:ok, _} = Sessions.dormant(context.session_id)
      refute File.exists?(context.workspace)

      elsewhere = Path.join(context.base, "pod-two")
      workspace = Path.join(elsewhere, "workspace")

      assert {:ok, _} =
               activate(context,
                 workspace: workspace,
                 state_dir: Path.join(elsewhere, "state"),
                 epoch: 2
               )

      assert File.read!(Path.join(workspace, "lib/deep/thing.ex")) == "defmodule Thing do end"
      assert File.read!(Path.join(workspace, "README.md")) == "# hello"
      assert %File.Stat{mode: mode} = File.stat!(Path.join(workspace, "README.md"))
      assert Bitwise.band(mode, 0o777) == 0o640
    end

    test "two at once produce one tree and one epoch", context do
      context = requires_tier(context)

      fake = start_supervised!({Fake, steps: [], default: {:text, "done"}})
      opts = activation(context, fake: fake, epoch: 1)

      results =
        1..8
        |> Task.async_stream(fn _ -> Sessions.activate(context.session_id, opts) end,
          max_concurrency: 8,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      pids = results |> Enum.map(fn {:ok, summary} -> summary.pid end) |> Enum.uniq()

      assert length(pids) == 1
      assert Sessions.active_count() == 1
      assert results |> Enum.map(fn {:ok, s} -> s.epoch end) |> Enum.uniq() == [1]
    end

    test "is idempotent: activating a running session is a lookup", context do
      context = requires_tier(context)
      assert {:ok, first} = activate(context)
      assert {:ok, second} = activate(context)

      assert first.pid == second.pid
      assert first.activated_at == second.activated_at
    end
  end

  describe "fencing" do
    test "a pod whose epoch has been passed refuses to activate at all", context do
      context = requires_tier(context)

      # The session has moved on to epoch 5. This pod still believes it is epoch 1.
      Storage.put_manifest(context.store, context.session_id, %{
        team: context.team,
        epoch: 5,
        last_seq: 12,
        head_hash: "sha256:whatever"
      })

      assert {:error, {:stale_epoch, 5, 1}} = activate(context, epoch: 1)
      assert Sessions.whereis(context.session_id) == nil

      # And it wrote nothing: no segment, and the manifest is the one it found.
      assert {:ok, []} = Storage.list_segments(context.store, context.session_id)
      assert {:ok, %{"epoch" => 5}} = Storage.get_manifest(context.store, context.session_id)
    end

    test "a running session that is fenced stops and discards its cache", context do
      context = requires_tier(context)
      assert {:ok, _} = activate(context, report: reporter_to(self()))

      File.write!(Path.join(context.workspace, "notes.md"), "the secret plan")
      run_turn(context.session_id, "hello")
      _ = await_sealed()

      {:ok, before} = Storage.list_segments(context.store, context.session_id)

      assert :ok = Sessions.fence(context.session_id, 2)
      eventually(fn -> Sessions.whereis(context.session_id) == nil end)

      # Nothing of this pod's reached storage after the fence, and nothing of it is left
      # on the PVC either — the cache was for a session this pod no longer owns.
      {:ok, unchanged} = Storage.list_segments(context.store, context.session_id)
      assert Enum.map(unchanged, & &1.key) == Enum.map(before, & &1.key)
      refute File.exists?(context.workspace)
      refute grep_plaintext(context.base, "the secret plan")
    end

    test "a stale epoch's segments are not merged into the restored history", context do
      context = requires_tier(context)
      assert {:ok, _} = activate(context)

      run_turn(context.session_id, "hello")
      assert {:ok, sealed} = Sessions.dormant(context.session_id)

      # A pod that was presumed lost wakes up and seals a segment under the old epoch,
      # covering ground the session has already covered.
      ghost = %{
        events: [%{"seq" => 1, "type" => "user_input", "data" => %{"text" => "from the ghost"}}],
        epoch: 1,
        first_seq: 1,
        last_seq: sealed.sealed_through,
        head_hash: "sha256:ghost"
      }

      {:ok, _} =
        Storage.seal_segment(context.store, context.session_id, data_key(context), ghost)

      elsewhere = Path.join(context.base, "pod-two")

      assert {:ok, _} =
               activate(context,
                 workspace: Path.join(elsewhere, "workspace"),
                 state_dir: Path.join(elsewhere, "state"),
                 epoch: 2
               )

      replayed = Troupe.replay_from(context.session_id, 0)
      refute Enum.any?(replayed, &(&1.data["text"] == "from the ghost"))
    end
  end

  defp await_dormant(timeout \\ 20_000) do
    receive do
      {:sealed, %{"type" => "session.dormant"} = report} -> report
      {:sealed, _other} -> await_dormant(timeout)
    after
      timeout -> flunk("the session never reported itself dormant")
    end
  end

  # Recursive grep over whatever is left on the "PVC", so the check is about bytes on
  # disk rather than about the paths this code happens to remember.
  defp grep_plaintext(root, needle) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.any?(fn path ->
      case File.read(path) do
        {:ok, body} -> String.contains?(body, needle)
        _ -> false
      end
    end)
  end
end
