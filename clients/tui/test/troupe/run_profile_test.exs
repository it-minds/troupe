defmodule Troupe.RunProfileTest do
  @moduledoc """
  `troupe run --profile NAME --title "…"`: the task on the platform as `/new`'s screen
  would start it, against `FakeRemote` signed in to. The task's inline tokens set the
  profile, the agent and where, win over the flags and are taken out before the agent
  reads it; a full profile is waited on, a line a wait, until the plane places it; the
  ceiling is the plane's refusal. A run without a profile stays on this computer.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers

  alias Troupe.CLI
  alias Troupe.CLI.RunTarget
  alias Troupe.Client
  alias Troupe.FakeRemote

  defp signed_in(opts \\ []) do
    {remote, url} =
      start_remote!(
        Keyword.merge([transport: :http, profiles: FakeRemote.profile_fixtures()], opts)
      )

    login!(remote, url)
    remote
  end

  defp parsed(argv) do
    {:ok, args} = CLI.parse(argv)
    args
  end

  test "--profile and --title parse, and are named in the help" do
    args = parsed(["run", "fix it", "--profile", "code", "--title", "Fix", "--headless"])
    assert %{mode: :run, profile: "code", title: "Fix", task: "fix it", agent_given: false} = args
    assert %{agent: "plan", agent_given: true} = parsed(["run", "plan", "x"])
    assert CLI.usage() =~ "--profile NAME"
  end

  test "--profile goes to the plane with the title, and the agent named" do
    remote = signed_in()

    {origin, params} =
      RunTarget.resolve(parsed(["run", "plan", "Fix the loop. Then test.", "--profile", "code"]))

    assert {:remote, _url} = origin

    assert %{
             profile: "code",
             agent: "plan",
             title: "Fix the loop",
             prompt: "Fix the loop. Then test."
           } = params

    {:ok, sid} = Client.create_session(origin, params)
    on_exit(fn -> Client.stop_session(sid) end)

    {"session.create", sent} =
      remote |> FakeRemote.calls() |> Enum.find(&match?({"session.create", _}, &1))

    assert %{"profile" => "code", "agent" => "plan", "title" => "Fix the loop"} = sent
  end

  test "the task's tokens win over the flags and leave the task" do
    signed_in()
    args = parsed(["run", "build", "@docs #plan write it up", "--profile", "code", "--title", "Up"])

    assert {{:remote, _}, %{profile: "docs", agent: "plan", prompt: "write it up", title: "Up"}} =
             RunTarget.resolve(args)

    # Something that names nothing is not a token, and stays.
    assert {{:remote, _}, %{prompt: "ask @nobody about #123"}} =
             RunTarget.resolve(parsed(["run", "ask @nobody about #123", "--profile", "code"]))
  end

  test "/local keeps it here, without asking which profile" do
    signed_in()

    assert {{:local, _ws}, %{prompt: "tidy up", title: "tidy up"}} =
             RunTarget.resolve(parsed(["run", "/local tidy up"]))

    assert {{:local, _ws}, %{prompt: "tidy up"}} = RunTarget.resolve(parsed(["run", "tidy up"]))
  end

  test "a full profile is waited on, a line a wait, and placed" do
    remote = signed_in()
    :ok = FakeRemote.room(remote, "code", %{"free" => 0, "total" => 8})
    {:ok, io} = StringIO.open("")
    {origin, params} = RunTarget.resolve(parsed(["run", "wait for it", "--profile", "code"]), io)

    task = Task.async(fn -> Client.create_session(origin, params) end)

    pending =
      Troupe.TestHelpers.eventually(fn ->
        Enum.find_value(FakeRemote.calls(remote), fn
          {"token.mint", %{"session_id" => sid}} -> sid
          _ -> nil
        end)
      end)

    assert {_in, out} = StringIO.contents(io)
    assert out =~ "troupe: waiting for a free place in code; asking again in 1 s"
    :ok = FakeRemote.place(remote, pending)
    assert {:ok, ^pending} = Task.await(task, 10_000)
    on_exit(fn -> Client.stop_session(pending) end)
  end

  test "at the ceiling the plane's sentence is the refusal" do
    remote = signed_in()
    :ok = FakeRemote.room(remote, "code", %{"free" => 3, "total" => 4}, 0)
    {origin, params} = RunTarget.resolve(parsed(["run", "one more", "--profile", "code"]))
    assert {:error, sentence} = Client.create_session(origin, params)
    assert sentence =~ "code allows 0 session(s) at once"
  end
end
