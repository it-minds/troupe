defmodule Troupe.PermissionRulesHeadlessTest do
  @moduledoc """
  Root #658 in a headless run against the daemon: a call a per-tool rule asks about is
  denied with nobody to ask, even under `--auto-approve`, and the line and the exit say
  which rule asked rather than suggesting `--auto-approve`; a call a rule denies is
  refused with the rule's sentence and asks nothing.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers

  defp headless(sid) do
    {:ok, io} = StringIO.open("")
    me = self()

    {:ok, _pid} =
      Troupe.UI.Headless.Printer.start_link(
        session_id: sid,
        target: "root",
        io: io,
        on_rest: fn code -> send(me, {:rest, code}) end
      )

    io
  end

  test "an ask asks under auto_approve, and the exit names the rule rather than the switch" do
    {sid, _, _} =
      start_session!(
        auto_approve: true,
        config: %{"permissions" => %{"ask" => ["shell(git status)"]}},
        script: [
          {:tools, [{"shell", %{"command" => "git status"}}]},
          {:text_and_tools, "left it", []}
        ]
      )

    io = headless(sid)
    say!(sid, "go")
    assert_receive {:rest, 3}, 15_000
    {_, out} = StringIO.contents(io)
    assert out =~ "approval needed for shell, asked by the rule ask shell(git status)"
    assert out =~ "calls a permission rule asks about, which --auto-approve does not answer"
    refute out =~ "(use --auto-approve)"
  end

  test "a deny refuses the call with the rule's sentence and asks nothing" do
    {sid, _, ws} =
      start_session!(
        config: %{"permissions" => %{"deny" => ["shell(touch)"]}},
        script: [
          {:tools, [{"shell", %{"command" => "touch made.txt"}}]},
          {:text_and_tools, "left it", []}
        ]
      )

    io = headless(sid)
    say!(sid, "go")
    assert_receive {:rest, 0}, 15_000
    {_, out} = StringIO.contents(io)
    assert out =~ "refused by the rule deny shell(touch)"
    refute out =~ "approval needed"
    refute File.exists?(Path.join(ws, "made.txt"))
  end
end
