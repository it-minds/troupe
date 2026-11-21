defmodule Troupe.Gateway.ActorNameTest do
  @moduledoc """
  The person an event names is written with their name, where the connection carries one.

  A client draws a person's initials and name from the event's `actor`; a token with no
  name claim gives the connection the subject twice, which is no name, and the event then
  says the subject alone so the client falls back to it rather than showing it as a name.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Dispatch
  alias Troupe.Protocol.Event.Actor

  @moduletag timeout: 60_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-actor-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "work")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)

    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_STATE_HOME", previous),
        else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    %{workspace: workspace}
  end

  test "a person's input carries their name; a name that is the subject again is left out",
       context do
    named = %{"subject" => "idp|7f3a", "display_name" => "Alice Example", "kind" => "user"}
    unnamed = %{"subject" => "bob@example.test", "display_name" => "bob@example.test", "kind" => "user"}

    assert {:ok, %{"session_id" => id}} =
             Dispatch.call(
               "session.create",
               %{"command_id" => "c-create", "workspace" => context.workspace, "worktree" => "never"},
               ctx(named)
             )

    on_exit(fn -> Troupe.stop_session(id) end)

    send_input(id, "c-alice", "from Alice", named)
    send_input(id, "c-bob", "from Bob", unnamed)

    alice = said(id, "from Alice")
    assert alice.actor.subject == "idp|7f3a"
    assert alice.actor.display_name == "Alice Example"

    bob = said(id, "from Bob")
    assert bob.actor.subject == "bob@example.test"
    assert bob.actor.display_name == nil
    refute Map.has_key?(Actor.to_json(bob.actor), "display_name")
  end

  defp send_input(id, command_id, text, principal) do
    assert {:ok, %{"accepted" => true}} =
             Dispatch.call(
               "input.send",
               %{"session_id" => id, "command_id" => command_id, "text" => text},
               ctx(principal)
             )
  end

  # The `user_input` with these words, once the session has written it: the first turn has
  # to end before a queued input is taken, and a loaded machine takes seconds over it.
  defp said(id, text, tries \\ 500) do
    case Enum.find(Troupe.events(id), &(&1.type == "user_input" and &1.data["text"] == text)) do
      nil when tries > 0 ->
        Process.sleep(20)
        said(id, text, tries - 1)

      event ->
        assert event, "no user_input with #{inspect(text)}"
        event
    end
  end

  defp ctx(principal) do
    %Dispatch.Context{
      principal: principal,
      scopes: [:observe, :control, :admin],
      connection: self(),
      next_subscription_id: "sub-1"
    }
  end
end
