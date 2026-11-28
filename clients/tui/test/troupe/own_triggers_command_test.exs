defmodule Troupe.OwnTriggersCommandTest do
  @moduledoc """
  A person's own triggers in the terminal (root #1235): `/triggers` lists the ones a yes of
  theirs turned on, each with whether it is on and when it runs next, its last run and what
  a run may spend; `/trigger off|on|remove NAME` changes one at the plane as them, and
  anybody else's is refused with the plane's sentence. `/proposal` with nothing open says how
  what a yes in this session turned on stands. A plane from before them says so, and a
  session on this computer has none to list.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client.OwnTriggers
  alias Troupe.FakeRemote

  @mine %{
    "id" => "trg-1",
    "team" => "eng",
    "name" => "rerun-weekly-numbers",
    "principal" => "svc:eng/own-alice",
    "enabled" => true,
    "cron" => "0 6 * * 1",
    "next_run_at" => "2026-11-30T06:00:00Z",
    "last_run" => %{
      "fired_at" => "2026-11-23T06:00:00Z",
      "state" => "done",
      "session_id" => "s-run"
    },
    "budget_micros" => 1_000_000,
    "session_id" => "s-prop",
    "artifact_id" => "art-weekly",
    "mine" => true
  }

  @theirs %{
    "id" => "trg-2",
    "team" => "eng",
    "name" => "nightly",
    "principal" => "svc:eng/nightly",
    "enabled" => true,
    "mine" => false
  }

  defp on_a_pod(remote_opts) do
    events = [%{"type" => "llm_response", "data" => FakeRemote.said("first line")}]
    session = FakeRemote.session(id: "s-prop", profile: "build", team: "eng", events: events)
    {remote, url} = start_remote!([sessions: [session]] ++ remote_opts)
    sid = attach!(connect!(remote, url), "s-prop")
    {pid, _screen} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)
    {remote, pid}
  end

  defp say(pid, line) do
    paste(pid, line)
    press(pid, "enter")
  end

  defp noticed?(pid, text), do: Enum.any?(user_state(pid).model.notices, &(&1 =~ text))

  test "/triggers lists the person's own, and /trigger switches one off and on and removes it" do
    {remote, pid} = on_a_pod(own_triggers: [@mine, @theirs])

    say(pid, "/triggers")

    eventually(fn ->
      noticed?(
        pid,
        "rerun-weekly-numbers in eng: on, cron 0 6 * * 1 (UTC), next Mon 30 Nov 06:00 UTC; last ran Mon 23 Nov 06:00 UTC: finished; up to $1.00 a run, as you"
      )
    end)

    refute noticed?(pid, "nightly in eng")

    say(pid, "/proposal")

    eventually(fn ->
      noticed?(
        pid,
        "nothing is proposed in this session now; turned on here: rerun-weekly-numbers in eng: on"
      )
    end)

    say(pid, "/trigger off rerun-weekly-numbers")
    eventually(fn -> noticed?(pid, "rerun-weekly-numbers in eng: off; last ran") end)

    assert {"trigger.own.disable", %{"trigger" => "rerun-weekly-numbers"}} in FakeRemote.calls(
             remote
           )

    say(pid, "/trigger on eng/rerun-weekly-numbers")

    eventually(fn ->
      noticed?(pid, "rerun-weekly-numbers in eng: on, cron 0 6 * * 1 (UTC), next")
    end)

    say(pid, "/trigger off nightly")

    eventually(fn ->
      noticed?(
        pid,
        "not switched off: eng/nightly runs as svc:eng/nightly, not as your own principal"
      )
    end)

    say(pid, "/trigger remove rerun-weekly-numbers")

    eventually(fn ->
      noticed?(pid, "rerun-weekly-numbers of eng is removed; its runs' sessions stay")
    end)

    say(pid, "/triggers")
    eventually(fn -> noticed?(pid, "no triggers of yours") end)

    say(pid, "/trigger pause it")

    eventually(fn ->
      noticed?(pid, "/trigger off NAME, /trigger on NAME or /trigger remove NAME")
    end)
  end

  test "a plane from before them says so" do
    {_remote, pid} = on_a_pod([])

    say(pid, "/triggers")
    eventually(fn -> noticed?(pid, "this plane does not let you change your own triggers yet") end)

    say(pid, "/trigger off rerun-weekly-numbers")

    eventually(fn ->
      noticed?(pid, "not switched off: this plane does not let you change your own triggers yet")
    end)
  end

  test "the words" do
    assert OwnTriggers.line(%{@mine | "enabled" => false, "next_run_at" => nil, "last_run" => nil}) ==
             "rerun-weekly-numbers in eng: off; not run yet; up to $1.00 a run, as you"

    assert OwnTriggers.line(%{
             @mine
             | "last_run" => %{
                 "fired_at" => "2026-11-23T06:00:00Z",
                 "state" => "skipped",
                 "reason" => "one at a time"
               }
           }) =~ "last ran Mon 23 Nov 06:00 UTC: skipped, one at a time"

    assert OwnTriggers.parse("remove eng/rerun") == {:ok, {:remove, "eng/rerun"}}
    assert {:error, _} = OwnTriggers.parse("off")
    assert OwnTriggers.not_here() =~ "a session on the platform"
  end
end
