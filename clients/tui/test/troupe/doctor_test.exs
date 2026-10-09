defmodule Troupe.DoctorCLITest do
  @moduledoc """
  `troupe doctor` (TUI Decision 123): the harness's checks, printed one per line with
  `troupe config` as the next step, and the exit status. The suite's config directory
  is scratch (test_helper.exs); this test writes its own user file there and puts it
  back. `async: false`: the file is shared, and while the bench runs it points
  `TROUPE_CONFIG_HOME` and `TROUPE_STATE_HOME` at its own directories.

  `troupe doctor --bench` (issue #390, root Decision 821) adds the offline bench's five
  scenarios after the checks, a line each and one for the whole, and `--json` is the
  same as one object.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Troupe.CLI
  alias Troupe.CLI.Doctor

  setup do
    user = Troupe.Config.user_path()
    before = File.read!(user)
    on_exit(fn -> File.write!(user, before) end)
    %{user: user}
  end

  test "with no provider it fails the provider line, naming troupe config, and exits 1", %{
    user: user
  } do
    File.write!(user, "version: 1\n")

    out = capture_io(fn -> assert Doctor.run(args(~w(doctor))) == 1 end)

    assert out =~
             ~r/^FAIL  provider +anthropic has no key, so no model can be asked; run `troupe config`$/m

    assert out =~ ~r/^ok    plane +none configured$/m
  end

  test "with the fake provider every line passes and it exits 0", %{user: user} do
    File.write!(user, "version: 1\nprovider: fake\n")

    out = capture_io(fn -> assert Doctor.run(args(~w(doctor))) == 0 end)
    assert out =~ ~r/^ok    provider +fake, claude-sonnet-5, no key needed$/m
    assert out =~ ~r/^ok    key +the fake provider asks nobody$/m
    assert out =~ ~r/^ok    key storage +/m
    refute out =~ "FAIL"
    refute out =~ "bench"
  end

  test "troupe doctor takes --bench, and --json with it or without" do
    assert {:ok, %{mode: :doctor, bench: true, json: false}} = CLI.parse(~w(doctor --bench))
    assert {:ok, %{mode: :doctor, bench: false, json: false}} = CLI.parse(~w(doctor))
    assert {:ok, %{mode: :doctor, bench: true, json: true}} = CLI.parse(~w(doctor --bench --json))
    assert {:ok, %{mode: :doctor, bench: false, json: true}} = CLI.parse(~w(doctor --json))
    assert CLI.usage() =~ "troupe doctor --bench"
  end

  test "--bench runs the checks, then the five scenarios offline, a line each, and exits 0 when all pass",
       %{user: user} do
    File.write!(user, "version: 1\nprovider: fake\n")
    # Nothing of the person's moves: their config and state directories are as they were,
    # and the bench's own directories are gone.
    homes = Enum.map(~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME), &System.get_env/1)
    before = Enum.map(homes, &tree/1)
    scratch = bench_dirs()

    out = capture_io(fn -> assert Doctor.run(args(~w(doctor --bench))) == 0 end)

    assert Enum.map(homes, &tree/1) == before
    assert bench_dirs() == scratch

    # The checks first, then the bench.
    [checks, bench] = String.split(out, ~r/^(?=ok    bench )/m, parts: 2)
    assert checks =~ ~r/^ok    plane +none configured$/m
    assert checks =~ ~r/^ok    key +the fake provider asks nobody$/m

    for {name, title} <- [
          {"tool_calls", "one turn of 30 tool calls"},
          {"cut_output", "a tool result over the limit is cut and read back"},
          {"compaction", "compaction fires at the configured share of the window"},
          {"cancel", "a cancelled turn leaves nothing running"},
          {"replay", "the log replays to the session it recorded"}
        ] do
      assert bench =~ ~r/^ok    bench #{name} +#{title}$/m
    end

    assert [_, seconds] =
             Regex.run(
               ~r/^ok    bench +5 of 5 passed in ([\d.]+) s, offline: a scripted model in this program's harness, no provider, key or network$/m,
               bench
             )

    assert String.to_float(seconds) < 60
    refute out =~ "FAIL"
  end

  test "a scenario that fails is a FAIL line naming what failed, and the exit is 1", %{user: user} do
    File.write!(user, "version: 1\nprovider: fake\n")
    budgets = put_in(Troupe.Bench.budgets(), ["tool_calls", "model_calls"], 30)

    out =
      capture_io(fn ->
        assert Doctor.run(args(~w(doctor --bench)),
                 bench: [budgets: budgets, only: ~w(tool_calls cancel)]
               ) == 1
      end)

    assert out =~
             ~r/^FAIL  bench tool_calls +one turn of 30 tool calls; failed: model calls in the turn 31 calls, over its budget of 30$/m

    assert out =~ ~r/^ok    bench cancel +a cancelled turn leaves nothing running$/m
    assert out =~ ~r/^FAIL  bench +1 of 2 failed in [\d.]+ s: tool_calls$/m
  end

  test "--bench --json is the same as one object, and prints nothing else", %{user: user} do
    File.write!(user, "version: 1\nprovider: fake\n")

    out =
      capture_io(fn ->
        assert Doctor.run(args(~w(doctor --bench --json)), bench: [only: ~w(replay)]) == 0
      end)

    assert {:ok, %{"passed" => true, "checks" => checks, "bench" => bench}} = Jason.decode(out)

    assert %{
             "name" => "provider",
             "state" => "ok",
             "detail" => "fake, claude-sonnet-5, no key needed"
           } in checks

    assert %{
             "name" => "bench replay",
             "state" => "ok",
             "detail" => "the log replays to the session it recorded"
           } in checks

    assert %{"name" => "bench", "state" => "ok"} = List.last(checks)
    assert %{"passed" => true, "failed" => [], "seconds" => seconds, "scenarios" => 1} = bench
    assert is_number(seconds)

    # Without --bench, the checks alone.
    out = capture_io(fn -> assert Doctor.run(args(~w(doctor --json))) == 0 end)
    assert {:ok, %{"passed" => true, "checks" => [_ | _]} = report} = Jason.decode(out)
    refute Map.has_key?(report, "bench")
  end

  defp args(argv) do
    {:ok, args} = CLI.parse(argv)
    args
  end

  # Every file under a directory with its content, so a write shows.
  defp tree(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.sort()
    |> Enum.map(&{&1, if(File.regular?(&1), do: File.read!(&1))})
  end

  defp bench_dirs, do: Path.wildcard(Path.join(System.tmp_dir!(), "troupe-bench-*"))
end
