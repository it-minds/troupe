defmodule Troupe.Gateway.ArchiveTest do
  @moduledoc """
  Archiving on a daemon (#1005): `session.archive` puts a session to sleep and takes it out
  of the session list, kept whole; `session.list` with `archived: true` lists it; it opens
  as before; `session.unarchive` brings it back. The mark is a file beside the log.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Dispatch

  @moduletag timeout: 60_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-archive-#{System.unique_integer([:positive])}")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf!(base) end)

    # Archiving stops a private session's sealer too, which the daemon's tree starts.
    start_supervised!(Troupe.Gateway.Private.Sealers)
    fake = start_supervised!({Troupe.LLM.Fake, steps: [], default: {:text, "done"}})
    %{base: base, state_dir: state_dir, fake: fake}
  end

  test "an archived session is asleep, out of the list, listed as archived, opens, and comes back",
       context do
    session = start!(context, "one")
    kept = start!(context, "two")
    assert session.id in ids(%{})

    assert {:ok, %{"state" => "dormant", "archived" => true}} =
             Dispatch.call("session.archive", %{"session_id" => session.id}, context(:admin))

    refute session.id in ids(%{})
    assert kept.id in ids(%{})
    assert ids(%{"archived" => true}) == [session.id]

    # It still opens, and says it is archived.
    assert {:ok, %{"archived" => true, "state" => "dormant"}} =
             Dispatch.call("session.get", %{"session_id" => session.id}, context(:observe))

    # Archiving again is what a retry does; unarchiving brings it back into the list.
    assert {:ok, %{"archived" => true}} =
             Dispatch.call("session.archive", %{"session_id" => session.id}, context(:admin))

    assert {:ok, %{"archived" => false}} =
             Dispatch.call("session.unarchive", %{"session_id" => session.id}, context(:admin))

    assert session.id in ids(%{})
    assert ids(%{"archived" => true}) == []
  end

  test "archiving is the person's own daemon's admin scope, and a session that is nowhere is not found",
       _context do
    assert {:error, %{message: "forbidden"}} =
             Dispatch.call("session.archive", %{"session_id" => "x"}, context(:observe))

    assert {:error, %{message: "not_found"}} =
             Dispatch.call(
               "session.archive",
               %{"session_id" => "20200101T000000-Nowher"},
               context(:admin)
             )
  end

  defp start!(context, name) do
    workspace = Path.join(context.base, name)
    File.mkdir_p!(workspace)

    {:ok, session} =
      Troupe.start_session(
        workspace: workspace,
        fake: context.fake,
        config_overrides: [provider: "fake", model: "fake-model", state_dir: context.state_dir]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    session
  end

  # The ids this test made, in the listing asked for, as the person's state dir has them.
  defp ids(filter) do
    {:ok, %{"sessions" => sessions}} =
      Dispatch.call("session.list", %{"filter" => filter}, context(:observe))

    sessions
    |> Enum.filter(&String.contains?(&1["workspace"] || "", "troupe-archive-"))
    |> Enum.map(& &1["id"])
  end

  defp context(scope) do
    scopes =
      case scope do
        :observe -> [:observe]
        :admin -> [:observe, :control, :admin]
      end

    %Dispatch.Context{
      principal: %{
        "subject" => "someone@example.test",
        "display_name" => "Someone",
        "kind" => "user"
      },
      scopes: scopes,
      connection: self(),
      next_subscription_id: "sub-1"
    }
  end
end
