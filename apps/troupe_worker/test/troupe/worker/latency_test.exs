defmodule Troupe.Worker.LatencyTest do
  @moduledoc """
  The two numbers the spec asks the final report to state: seal lag, and activation.

  **Seal lag** is how long a durable event spends existing only on a pod's volume. It is
  the window in which losing the volume loses the event, so it is the size of the promise
  "a session survives its pod" — measured from the append that ends a turn to the sealer's
  report that the segment is in object storage.

  **Activation** is how long somebody waits between asking for a dormant session and
  having one they can steer. Measured twice, because the two answers are different
  products: *warm*, with the workspace archive still cached on this pod's volume, and
  *cold*, with nothing cached at all — every byte from object storage, decrypted, and the
  log replayed.

  These are measurements rather than assertions, and the bounds are deliberately loose:
  what the report needs is a number from a real durable tier, and a test that failed on a
  slow laptop would be a test people delete.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.Worker.Cache

  @moduletag timeout: 300_000

  # Five of each, reported as a median and a worst case. Enough to be a number rather
  # than an anecdote, few enough that a full durable round trip per sample is bearable.
  @samples 5

  test "seal lag, and activation warm and cold", context do
    context = requires_tier(context)

    seal = measure_seal(context)
    warm = measure_activation(context, :warm)
    cold = measure_activation(context, :cold)

    IO.puts("""

    measured against a real object store and key manager

      seal lag        median #{seal.median}ms   max #{seal.max}ms   (#{@samples} turns)
      activation warm median #{warm.median}ms   max #{warm.max}ms   (#{@samples} activations)
      activation cold median #{cold.median}ms   max #{cold.max}ms   (#{@samples} activations)
    """)

    # Loose on purpose: the numbers are the point, and a bound tight enough to be
    # interesting would be a bound that fails on somebody else's machine.
    assert seal.max < 30_000
    assert warm.max < 30_000
    assert cold.max < 30_000

    # The one comparison worth asserting: a warm activation does less work than a cold
    # one, which is the whole reason the cache exists.
    assert warm.median <= cold.median + 250
  end

  # -- seal lag ---------------------------------------------------------------

  # From the turn's last durable append to the report that says its segment is in object
  # storage. The sealer reports *after* the upload, which is what makes this a measure of
  # durability rather than of intent.
  defp measure_seal(context) do
    assert {:ok, _} = activate(context, report: reporter_to(self()))
    _ = await_sealed()

    for n <- 1..@samples do
      drain_reports()
      run_turn(context.session_id, "turn #{n}")
      head = Troupe.head_seq(context.session_id)
      appended = System.monotonic_time(:millisecond)

      # The *first* report that covers this turn, not the last one before things go
      # quiet: waiting for quiet would measure the quiet window rather than the lag.
      await_seal_through(head)
      System.monotonic_time(:millisecond) - appended
    end
    |> summarise()
  end

  defp await_seal_through(seq) do
    receive do
      {:sealed, %{"last_seq" => last}} when last >= seq -> :ok
      {:sealed, _earlier} -> await_seal_through(seq)
    after
      30_000 -> flunk("nothing sealed through #{seq} within 30s")
    end
  end

  defp drain_reports do
    receive do
      {:sealed, _report} -> drain_reports()
    after
      0 -> :ok
    end
  end

  # -- activation -------------------------------------------------------------

  defp measure_activation(context, kind) do
    for _n <- 1..@samples do
      {:ok, _} = activate(context)
      run_turn(context.session_id, "something to come back to")
      {:ok, _} = Sessions.dormant(context.session_id)

      # Cold means nothing on this volume: the cache is what a pod that has run this
      # session before has, and a pod that has never seen it does not.
      if kind == :cold, do: Cache.evict(context.session_id, context.state_dir)

      started = System.monotonic_time(:millisecond)
      {:ok, _} = activate(context)
      elapsed = System.monotonic_time(:millisecond) - started

      # Ready means steerable, not merely started.
      assert Troupe.agent_tree(context.session_id) != []

      {:ok, _} = Sessions.dormant(context.session_id)
      elapsed
    end
    |> summarise()
  end

  defp summarise(samples) do
    sorted = Enum.sort(samples)
    %{median: Enum.at(sorted, div(length(sorted), 2)), max: List.last(sorted)}
  end
end
