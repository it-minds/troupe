# The cluster tests kill the operator on purpose, so its crash reports are expected
# output rather than a signal. They are captured and printed only with a failure.
Logger.configure(level: :warning)

# The `:cluster` tests need a real API server. Without one they are *excluded* rather
# than failed. `ClusterCase` has always said it skips them loudly, but announcing it in
# `setup_all` and then letting every test flunk on a missing `:conn` is not skipping —
# it is a red suite on every laptop and every CI runner that has no cluster, which
# teaches people to read red as normal. Excluding the tag is what ExUnit calls skipping;
# the message below is the loud part. `--include cluster` overrides it.
exclude =
  case Troupe.Operator.ClusterCase.cluster() do
    {:ok, _conn} ->
      []

    {:error, reason} ->
      IO.puts(:stderr, """

      SKIPPED: no Kubernetes cluster (#{inspect(reason)}).
      The `:cluster` tests prove the operator's done criteria and did not run:

          scripts/kind-up
          helm upgrade --install troupe charts/troupe -n troupe-system --create-namespace
      """)

      [:cluster]
  end

# `:e2e` is excluded always, not conditionally. Those run against a whole Troupe on a
# real cluster, they delete pods and inject faults, and `mix test` must never be the way
# somebody discovers that. `mix troupe.e2e` is the only way in, and it checks which
# cluster it is pointed at before it starts.
ExUnit.start(capture_log: true, exclude: [:e2e | exclude])
