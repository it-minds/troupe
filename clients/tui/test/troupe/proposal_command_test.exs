defmodule Troupe.ProposalCommandTest do
  @moduledoc """
  What the harness proposes in a session on the platform (root #1208), in the terminal: the
  log's `proposal_made` as a line naming the question and how to answer it, and
  `/proposal yes|later|never` answering it, a yes at the plane as the person and a no to the
  session, each answer's line following from the log. A session on this computer has
  nothing proposed.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Client.Proposal
  alias Troupe.FakeRemote

  @made %{
    "id" => "proposal-1",
    "kind" => "trigger",
    "key" => "artifact:art-weekly",
    "title" => "Rerun this report every Monday?",
    "why" => "It was built from live data (1 page fetched), which a rerun reads again.",
    "options" => ["accepted", "later", "never"],
    "mode" => "direct",
    "draft" => %{
      "profile" => "dev",
      "terms" => %{"budget_micros" => 1_000_000},
      "artifact" => %{"id" => "art-weekly", "title" => "Weekly numbers"}
    }
  }

  defp on_a_pod(fields \\ []) do
    events = [%{"type" => "llm_response", "data" => FakeRemote.said("first line")}]

    session =
      FakeRemote.session([id: "s-prop", profile: "build", team: "eng", events: events] ++ fields)

    {remote, url} = start_remote!(sessions: [session])
    sid = attach!(connect!(remote, url), "s-prop")
    {pid, _screen} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)
    {remote, sid, pid}
  end

  defp notices(pid), do: user_state(pid).model.notices

  defp say(pid, line) do
    paste(pid, line)
    press(pid, "enter")
  end

  defp noted?(sid, text),
    do: Enum.any?(Client.events(sid), &(&1.type == :remote_note and &1.data.text =~ text))

  test "the proposal is a line, and /proposal yes turns it on at the plane, the answer's line following" do
    {remote, sid, pid} = on_a_pod()

    say(pid, "/proposal")

    eventually(fn ->
      Enum.any?(notices(pid), &(&1 =~ "nothing is proposed in this session now"))
    end)

    FakeRemote.emit(remote, "s-prop", "proposal_made", @made)

    eventually(fn ->
      noted?(sid, "Troupe asks: Rerun this report every Monday? It was built from live data") and
        noted?(
          sid,
          "Runs as you, on dev, up to $1.00 a run; each run is a new version of \"Weekly numbers\". /proposal yes turns it on"
        )
    end)

    say(pid, "/proposal yes")

    eventually(fn ->
      Enum.any?(
        notices(pid),
        &(&1 =~ "Turned on: the trigger rerun-weekly-numbers of eng reruns it as you")
      )
    end)

    assert Enum.any?(
             FakeRemote.calls(remote),
             &match?(
               {"session.proposal.accept", %{"session_id" => "s-prop", "id" => "proposal-1"}},
               &1
             )
           )

    eventually(fn ->
      noted?(
        sid,
        "turned on a rerun of \"Weekly numbers\" as the trigger rerun-weekly-numbers of eng"
      )
    end)

    say(pid, "/proposal yes")

    eventually(fn ->
      Enum.any?(notices(pid), &(&1 =~ "nothing is proposed in this session now"))
    end)

    refute Enum.any?(Client.events(sid), &(&1.type == :input))
  end

  test "/proposal never says no to the session, and the answer's line follows" do
    {remote, sid, pid} = on_a_pod()
    FakeRemote.emit(remote, "s-prop", "proposal_made", @made)
    eventually(fn -> noted?(sid, "Troupe asks:") end)

    say(pid, "/proposal never")
    eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "not proposed again for this report")) end)

    assert Enum.any?(
             FakeRemote.calls(remote),
             &match?(
               {"session.proposal.answer", %{"id" => "proposal-1", "decision" => "never"}},
               &1
             )
           )

    eventually(fn -> noted?(sid, "said never for rerunning \"Weekly numbers\"") end)

    say(pid, "/proposal sometime")

    eventually(fn ->
      Enum.any?(notices(pid), &(&1 =~ "/proposal yes, /proposal later, /proposal never"))
    end)
  end

  test "the lines in words" do
    assert Proposal.made(
             Map.merge(@made, %{
               "mode" => "unavailable",
               "reason" => "the profile dev asks before web_fetch"
             })
           ) =~
             "It cannot run here unattended: the profile dev asks before web_fetch. /proposal later or /proposal never answers it."

    assert Proposal.answered(%{"decision" => "later", "by_name" => "Ada"}, "Weekly numbers") ==
             "Ada said not now to rerunning \"Weekly numbers\"."

    assert Proposal.accepted(%{"yaml" => "kind: Trigger\n", "path" => "triggers/eng/x.yaml"}) =~
             "Commit this as triggers/eng/x.yaml"

    assert Proposal.not_here() =~ "nothing on this computer runs one"
  end
end
