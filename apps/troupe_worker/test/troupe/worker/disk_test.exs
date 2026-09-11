defmodule Troupe.Worker.DiskTest do
  @moduledoc """
  What a pod gives up when its volume fills, and what it never gives up.

  The done item has two halves. The plane stops placing on a pod above the high
  watermark, which it does from the pod's own heartbeat. And the pod evicts dormant
  caches until it is back under the low watermark **without touching active
  workspaces** — because a cache is a copy of something already in object storage and an
  active workspace is the only copy of work in progress.

  The measurement is injected. A test cannot fill a developer's disk to prove what
  happens when a PVC fills, and the thing worth proving is the policy; that `df` reports
  the truth is checked separately, against `df`.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.Worker.{Cache, Disk}
  alias Troupe.Worker.Disk.Watch
  alias Troupe.Worker.Session.Workspace

  @moduletag timeout: 180_000

  describe "measuring" do
    test "reads the filesystem rather than summing what it knows about", context do
      context = requires_tier(context)
      usage = Disk.usage(context.base)

      assert usage.total_bytes > 0
      assert usage.used_bytes > 0
      assert usage.fraction > 0.0 and usage.fraction <= 1.0
      assert usage.used_bytes + usage.available_bytes <= usage.total_bytes
    end

    test "an unreadable path is zero rather than a crash" do
      usage = Disk.usage("/this/does/not/exist/at/all")
      assert usage.total_bytes == 0
      assert usage.fraction == 0.0
    end

    test "pressure is the two watermarks, and nothing else" do
      assert Disk.pressure(%{fraction: 0.5}) == :ok
      assert Disk.pressure(%{fraction: 0.85}) == :high
      assert Disk.pressure(%{fraction: 0.95}) == :critical
      assert Disk.pressure(%{fraction: 0.75}, high: 0.70) == :high
    end
  end

  describe "eviction" do
    test "evicts least recently used until back under the low watermark", context do
      context = requires_tier(context)

      # Four dormant caches, touched in a known order. The oldest should go first.
      for id <- ~w(oldest older newer newest) do
        Cache.put_workspace(id, context.state_dir, 1, :crypto.strong_rand_bytes(4_096))
        Process.sleep(5)
        Cache.touch(id, context.state_dir)
      end

      assert Cache.entries(context.state_dir) |> Enum.map(& &1.session_id) ==
               ~w(oldest older newer newest)

      watch = start_watch(context, quota: 12_000)

      report = Watch.sweep(watch)
      assert report.outcome == :ok

      # Enough went to get under, and no more: eviction is not a purge.
      remaining = Cache.entries(context.state_dir) |> Enum.map(& &1.session_id)
      assert "newest" in remaining
      assert report.evicted != []
      assert List.first(report.evicted) == "oldest"
      refute Enum.any?(report.evicted, &(&1 == "newest"))
    end

    test "never evicts an active session's workspace", context do
      context = requires_tier(context)

      # One real, active session, and one dormant cache alongside it.
      assert {:ok, _} = activate(context)
      run_turn(context.session_id, "hello")
      File.write!(Path.join(context.workspace, "work-in-progress.txt"), "the only copy")

      Cache.put_workspace(context.session_id, context.state_dir, 1, :crypto.strong_rand_bytes(4_096))
      Cache.put_workspace("a-dormant-one", context.state_dir, 1, :crypto.strong_rand_bytes(4_096))

      # Well past the low watermark and impossible to get under: the pod must give up
      # what it may and stop, not reach for the running session.
      watch = start_watch(context, quota: 1)

      report = Watch.sweep(watch)

      assert report.outcome == :still_above
      assert "a-dormant-one" in report.evicted
      refute context.session_id in report.evicted

      # The running session is untouched: its workspace, its tree and its cache.
      assert File.read!(Path.join(context.workspace, "work-in-progress.txt")) == "the only copy"
      assert Sessions.whereis(context.session_id)
      assert Cache.get_workspace(context.session_id, context.state_dir) != :miss
    end

    test "does nothing at all below the low watermark", context do
      context = requires_tier(context)
      Cache.put_workspace("untouched", context.state_dir, 1, :crypto.strong_rand_bytes(1_024))

      watch = start_watch(context, quota: 1_000_000_000)

      report = Watch.sweep(watch)
      assert report.evicted == []
      assert report.outcome == :ok
      assert Cache.get_workspace("untouched", context.state_dir) != :miss
    end
  end

  describe "the cache itself" do
    test "holds sealed bytes and hands back the newest generation", context do
      context = requires_tier(context)
      old = :crypto.strong_rand_bytes(512)
      new = :crypto.strong_rand_bytes(512)

      :ok = Cache.put_workspace("s-1", context.state_dir, 10, old)
      :ok = Cache.put_workspace("s-1", context.state_dir, 20, new)

      assert {:ok, 20, ^new} = Cache.get_workspace("s-1", context.state_dir)

      # Superseded generations go: three copies of the same workspace is three times the
      # disk for no benefit.
      assert Cache.entries(context.state_dir)
             |> Enum.find(&(&1.session_id == "s-1"))
             |> Map.fetch!(:bytes) < byte_size(old) + byte_size(new)
    end

    test "a miss is a miss, not a crash", context do
      context = requires_tier(context)
      assert Cache.get_workspace("never-heard-of-it", context.state_dir) == :miss
      assert Cache.evict("never-heard-of-it", context.state_dir) == 0
    end
  end

  describe "restoring" do
    test "a session with a warm cache comes back from disk, not from storage", context do
      context = requires_tier(context)

      assert {:ok, _} = activate(context)
      File.write!(Path.join(context.workspace, "notes.md"), "worth keeping")
      run_turn(context.session_id, "hello")
      assert {:ok, _} = Sessions.dormant(context.session_id)

      # Dormancy left the encrypted archive behind, and only that.
      assert {:ok, _seq, _sealed} = Cache.get_workspace(context.session_id, context.state_dir)
      refute File.exists?(context.workspace)

      assert {:ok, summary} = activate(context, epoch: 2)
      assert summary.status == :active
      assert File.read!(Path.join(context.workspace, "notes.md")) == "worth keeping"
    end
  end

  # -- helpers ----------------------------------------------------------------

  # A watch whose idea of "full" is this pod's caches plus its workspaces against a
  # quota, so a test can put the volume wherever it needs it.
  defp start_watch(context, opts) do
    quota = Keyword.fetch!(opts, :quota)
    state_dir = context.state_dir

    usage = fn ->
      used = Workspace.size(state_dir)
      %{total_bytes: quota, used_bytes: used, available_bytes: max(quota - used, 0), fraction: used / quota}
    end

    start_supervised!(
      {Watch,
       name: nil, state_dir: state_dir, usage: usage, low: 0.70, high: 0.80, interval_ms: 600_000}
    )
  end
end
