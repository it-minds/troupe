defmodule Troupe.MemoryScreenTest do
  @moduledoc """
  `/memory` (root #55): what the troupe remembers for the person, as entries — each `## Topic`
  of a level's document — through this computer's daemon linked to `FakeRemote`. In effect
  per team, the closest level winning a topic and naming what it replaces; the organisation's
  and a team's read here; Only you's entries added, edited in the editor or in a box, and
  forgotten after a confirm line, a clash said; a save over a version saved elsewhere shown
  beside it and reloaded; the versions side by side and a roll back; who wrote each line;
  under Local only, read-only from this machine's copy. Drawn on the headless renderer.
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
      "text" => "## Prices\nThe framework agreement.\n\n## Consent\nAsk first."
    }
  ]

  @own [
    %{
      "version" => 1,
      "text" => "## Tone\nKeep answers short.",
      "changed_by" => "alice",
      "changed_at" => "2026-10-25T09:00:00Z"
    }
  ]

  setup do
    previous = Map.new(~w(VISUAL EDITOR), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Application.delete_env(:troupe, :edit_file)
      Application.delete_env(:troupe, :local_only)

      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)
    end)

    {remote, url} = start_remote!(transport: :http, memory: @memory, own_versions: @own)
    login!(remote, url)
    reattach()
    eventually(fn -> match?({:ok, %{"linked" => true}}, Link.call("identity.get", %{})) end)
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)
    %{remote: remote, pid: pid, session: session}
  end

  defp open(pid) do
    type(pid, "/memory")
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :own_memory end)
  end

  defp editor(words) do
    Application.put_env(:troupe, :edit_file, fn path ->
      File.write!(path, words)
      :ok
    end)
  end

  test "in effect per team, the levels read, and Only you's entries added, edited and forgotten",
       ctx do
    %{pid: pid, session: session} = ctx
    open(pid)

    text = screen_text(pid, session)
    assert text =~ "1 In effect"
    assert text =~ "2 ◉ Everyone at your organisation 2 · read"
    assert text =~ "3 ◎ design 2 · read"
    assert text =~ "4 ○ Only you 1"
    assert text =~ "A new session in design starts knowing this"
    # The closest level wins a topic, and says what it replaces.
    assert text =~ ~r/Tone · from Only you\s+Keep answers short\./
    assert text =~ "replaces Everyone at your organisation’s"
    assert text =~ ~r/Prices · from design\s+The framework agreement\./
    assert text =~ ~r/Consent · from design\s+Ask first\./

    # Enter reads one whole, with what it replaces under it.
    press(pid, "enter")
    text = screen_text(pid, session)
    assert text =~ "Tone · Only you — Esc back"
    assert text =~ "replaces Everyone at your organisation’s: Write plain English."
    press(pid, "esc")

    # A team's is read here by a member: only its admins change it.
    press(pid, "3")
    press(pid, "a")

    assert screen_text(pid, session) =~
             "design is read here: only design's team admins can change it"

    # Only you: edited in the editor, over the version it was made on.
    press(pid, "4")
    editor("Keep answers short and kind.")
    press(pid, "e")
    assert eventually(fn -> screen_text(pid, session) =~ "Saved “Tone”. Version 2" end)
    assert screen_text(pid, session) =~ "Keep answers short and kind."

    # A topic it has already is refused; one a lower level has is said to be replaced.
    press(pid, "a")
    type(pid, "tone")
    press(pid, "enter")

    assert screen_text(pid, session) =~
             "Only you already has a memory called “Tone”. Edit that one instead"

    press(pid, "esc")

    editor("Quote in euros.")
    press(pid, "a")
    type(pid, "Prices")
    press(pid, "enter")
    assert eventually(fn -> screen_text(pid, session) =~ "Saved “Prices”. Version 3" end)
    press(pid, "1")
    assert screen_text(pid, session) =~ ~r/Prices · from Only you\s+Quote in euros\./

    # Forgotten after its confirm line; any other key keeps it.
    press(pid, "4")
    press(pid, "down")
    press(pid, "f")
    assert screen_text(pid, session) =~ "Forget “Prices”? New sessions stop starting with it."
    press(pid, "n")
    assert screen_text(pid, session) =~ "kept"
    press(pid, "f")
    press(pid, "y")

    assert eventually(fn ->
             screen_text(pid, session) =~ "Forgotten. New sessions will not start with “Prices”."
           end)

    assert screen_text(pid, session) =~ "4 ○ Only you 1"

    # With no editor of their own, the words are written in a box here.
    Application.delete_env(:troupe, :edit_file)
    System.delete_env("VISUAL")
    System.delete_env("EDITOR")
    press(pid, "a")
    type(pid, "Lists")
    press(pid, "enter")
    assert screen_text(pid, session) =~ "Lists — saves to Only you · your new sessions in any team"
    type(pid, "Bullets when summarising.")
    press(pid, "s", ["ctrl"])
    assert eventually(fn -> screen_text(pid, session) =~ "Saved “Lists”. Version 5" end)
  end

  test "a save over a version saved elsewhere shows both and reloads; the versions side by side and a roll back; who wrote it",
       ctx do
    %{pid: pid, session: session, remote: remote} = ctx
    open(pid)
    press(pid, "4")

    :ok = FakeRemote.save_own(remote, "## Tone\nChanged on the laptop.")
    editor("Mine instead.")
    press(pid, "e")

    assert eventually(fn -> screen_text(pid, session) =~ "yours, not saved" end)
    text = screen_text(pid, session)
    assert text =~ "## Tone\nMine instead." or text =~ "Mine instead."
    assert text =~ "version 2, saved since"
    assert text =~ "Changed on the laptop."
    press(pid, "l")

    assert eventually(fn ->
             screen_text(pid, session) =~ "reloaded version 2; your edit was not saved"
           end)

    assert screen_text(pid, session) =~ "Changed on the laptop."

    # h: the versions; Enter two side by side; r saves an old one again over the one in force.
    press(pid, "h")
    text = screen_text(pid, session)
    assert text =~ "versions of your memory"
    assert text =~ "v2 · alice"
    assert text =~ "in force"
    press(pid, "down")
    press(pid, "enter")
    text = screen_text(pid, session)
    assert text =~ "version 1"
    assert text =~ "version 2"
    assert text =~ "Keep answers short."
    press(pid, "x")
    press(pid, "r")
    assert eventually(fn -> screen_text(pid, session) =~ "Rolled back to version 1. Version 3" end)

    # b: who wrote each line, as a column.
    press(pid, "b")
    text = screen_text(pid, session)
    assert text =~ "who wrote each line"
    assert text =~ ~r/v3 alice\s+Keep answers short\./
  end

  test "under Local only every level is read from this machine's copy, and nothing is changed",
       ctx do
    %{pid: pid, session: session, remote: remote} = ctx
    # The copy this machine holds, as the daemon fetched it at the link.
    eventually(fn -> match?({:ok, %{held: [_ | _]}}, Troupe.Client.memory_status()) end)
    Application.put_env(:troupe, :local_only, true)
    # The link says Local only as it connects; the next test's is not.
    reattach()

    on_exit(fn ->
      Application.delete_env(:troupe, :local_only)
      reattach()
    end)

    # Whatever the link asked as it connected has been asked before the screen opens.
    asked = fn -> Enum.count(FakeRemote.calls(remote), &match?({"me.memory" <> _, _}, &1)) end

    before =
      eventually(fn ->
        now = asked.()
        Process.sleep(200)
        now == asked.() && now
      end)

    open(pid)
    text = screen_text(pid, session)
    assert text =~ "Local only: the plane is not asked."
    assert text =~ "4 ○ Only you 1 · read"

    press(pid, "4")
    press(pid, "e")

    assert screen_text(pid, session) =~
             "Local only: the plane is not asked, so your memory is read-only here"

    assert asked.() == before
  end

  defp reattach do
    case :sys.get_state(Link) do
      %{client: client} when is_pid(client) -> Troupe.Protocol.Client.close(client)
      _ -> :ok
    end

    {:ok, _} = Link.call("identity.get", %{})
  end
end
