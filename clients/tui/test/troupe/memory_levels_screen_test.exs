defmodule Troupe.MemoryLevelsScreenTest do
  @moduledoc """
  `/memory` (root #55) by role: a team admin changes their team's level, a platform admin the
  organisation's, through this computer's daemon's forwarded `admin.memory.preview` and
  `admin.memory.put` as them, linked to `FakeRemote`; everybody else reads those levels and is
  told who can change them. A save says where it goes and what it reaches first, a clash is
  said across levels as the plane compares topics, a conflict shows both, and a role the plane
  has taken away since is refused in its own words. Drawn on the headless renderer.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client.Daemon.Link
  alias Troupe.FakeRemote

  @memory [
    %{
      "scope" => "organisation",
      "version" => 4,
      "text" => "## Tone\nWrite plain English.\n\n## Prices\nUse the rate card.",
      "changed_by" => "camilla@example.test"
    },
    %{
      "scope" => "team",
      "name" => "design",
      "version" => 2,
      "text" => "## Prices\nThe framework agreement.\n\n## Consent\nAsk first.",
      "changed_by" => "jonas@example.test"
    }
  ]

  @own [%{"version" => 1, "text" => "## Lists\nBullets.", "changed_by" => "alice"}]

  setup context do
    on_exit(fn -> Application.delete_env(:troupe, :edit_file) end)

    {remote, url} =
      start_remote!(
        transport: :http,
        memory: @memory,
        own_versions: @own,
        memory_roles: context[:roles],
        plane_roles: context[:plane_roles]
      )

    login!(remote, url)
    reattach()
    eventually(fn -> match?({:ok, %{"linked" => true}}, Link.call("identity.get", %{})) end)
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)
    type(pid, "/memory")
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :own_memory end)
    %{remote: remote, pid: pid, session: session}
  end

  defp editor(words) do
    Application.put_env(:troupe, :edit_file, fn path ->
      File.write!(path, words)
      :ok
    end)
  end

  defp puts(remote), do: for({"admin.memory.put", params} <- FakeRemote.calls(remote), do: params)

  @tag roles: %{"platform_admin" => false, "team_admin" => ["design"]}
  test "a team admin changes their team's level, the clashes and what it reaches said first", ctx do
    %{pid: pid, session: session, remote: remote} = ctx

    text = screen_text(pid, session)
    assert text =~ "2 ◉ Everyone at your organisation 2 · read"
    assert text =~ ~r/3 ◎ design 2\s/
    refute text =~ "design 2 · read"

    # The organisation's is read here, and says who can change it.
    press(pid, "2")
    press(pid, "a")

    assert screen_text(pid, session) =~
             "Everyone at your organisation is read here: only platform administrators can change it"

    # Who last changed each of the team's entries, and in how many sessions it was used.
    press(pid, "3")

    assert screen_text(pid, session) =~
             ~r/Prices\s+The framework agreement\.\s+jonas@example\.test · .* · used in 3 sessions/

    # A topic the team has already, compared as the plane compares them, is refused.
    press(pid, "a")
    type(pid, "  PRICES")
    text = screen_text(pid, session)
    assert text =~ "saves to design · new sessions in design"
    assert text =~ "reaches 3 running sessions at their next turn"
    press(pid, "enter")

    assert screen_text(pid, session) =~
             "Team design already has a memory called “Prices”. Edit that one instead, or pick another topic."

    press(pid, "esc")

    # One the organisation has is said to be replaced for everyone in the team, and saved.
    editor("Short sentences.")
    press(pid, "a")
    type(pid, "tone")
    press(pid, "enter")

    assert eventually(fn ->
             screen_text(pid, session) =~
               "Saved “tone”. Version 3: new sessions in design start with it"
           end)

    assert [%{"scope" => "team", "name" => "design", "version" => 2, "entries" => entries}] =
             puts(remote)

    assert Enum.map(entries, & &1["topic"]) == ["Prices", "Consent", "tone"]

    assert [%{"action" => "memory.put", "subject" => "team/design", "version" => %{"to" => 3}}] =
             FakeRemote.memory_audit(remote)

    assert screen_text(pid, session) =~ "3 ◎ design 3"

    # Edited and forgotten too, each over the version read.
    editor("The framework agreement, always.")
    press(pid, "e")
    assert eventually(fn -> screen_text(pid, session) =~ "Saved “Prices”. Version 4" end)
    press(pid, "f")
    assert screen_text(pid, session) =~ "Forget “Prices”? New sessions stop starting with it."
    assert screen_text(pid, session) =~ "reaches 3 running sessions at their next turn"
    press(pid, "y")

    assert eventually(fn ->
             screen_text(pid, session) =~ "Forgotten. New sessions will not start with “Prices”."
           end)

    assert %{"version" => 5, "text" => "## Consent\n\nAsk first.\n\n## tone\n\nShort sentences."} =
             Enum.find(FakeRemote.memory(remote), &(&1["name"] == "design"))
  end

  @tag roles: %{"platform_admin" => true, "team_admin" => []}
  test "a platform admin changes the organisation's; one saved elsewhere since shows both", ctx do
    %{pid: pid, session: session, remote: remote} = ctx

    text = screen_text(pid, session)
    assert text =~ ~r/2 ◉ Everyone at your organisation 2\s/
    assert text =~ "3 ◎ design 2 · read"

    press(pid, "3")
    press(pid, "e")

    assert screen_text(pid, session) =~
             "design is read here: only design's team admins can change it"

    press(pid, "2")
    :ok = FakeRemote.save_level(remote, "organisation", nil, "## Tone\nWrite plainer English.")
    editor("Write plain Danish.")
    press(pid, "e")

    assert eventually(fn -> screen_text(pid, session) =~ "yours, not saved" end)
    text = screen_text(pid, session)
    assert text =~ "Write plain Danish."
    assert text =~ "version 5, saved since"
    assert text =~ "Write plainer English."

    assert text =~
             "Not saved: Everyone at your organisation was saved somewhere else since, version 5."

    press(pid, "l")
    assert eventually(fn -> screen_text(pid, session) =~ "reloaded version 5" end)

    editor("Write plain Danish.")
    press(pid, "e")

    assert eventually(fn ->
             screen_text(pid, session) =~
               "Saved “Tone”. Version 6: new sessions in every team start with it"
           end)

    assert [%{"scope" => "organisation", "version" => 5}] =
             Enum.filter(puts(remote), &(&1["version"] == 5))
  end

  @tag roles: %{"platform_admin" => false, "team_admin" => ["design"]}
  @tag plane_roles: %{"platform_admin" => false, "team_admin" => []}
  test "a role the plane has taken away since is refused in the plane's words, and nothing is saved",
       ctx do
    %{pid: pid, session: session, remote: remote} = ctx

    press(pid, "3")
    press(pid, "a")

    assert screen_text(pid, session) =~
             "only design's team admins and the platform administrators change design's memory"

    editor("Anything.")
    type(pid, "Delivery")
    press(pid, "enter")

    assert eventually(fn ->
             screen_text(pid, session) =~
               "not saved: only design's team admins and the platform administrators change design's memory"
           end)

    assert %{"version" => 2} = Enum.find(FakeRemote.memory(remote), &(&1["name"] == "design"))
    assert FakeRemote.memory_audit(remote) == []
  end

  defp reattach do
    case :sys.get_state(Link) do
      %{client: client} when is_pid(client) -> Troupe.Protocol.Client.close(client)
      _ -> :ok
    end

    {:ok, _} = Link.call("identity.get", %{})
  end
end
