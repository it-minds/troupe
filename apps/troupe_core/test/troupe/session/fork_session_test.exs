defmodule Troupe.Session.ForkSessionTest do
  @moduledoc """
  Root Decision 812: a session on this machine forked into a second one. The child's log
  opens with `session_forked` and goes on with the parent's events, resealed under its own
  numbering, so its chain verifies on its own and its agent starts from the parent's
  conversation; the parent is not changed; and the child is a session of its own, not a
  branch of the parent.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Events
  alias Troupe.Session.Log

  test "the child's log is the parent's, after session_forked, and its agent goes on from it",
       context do
    %{session: parent} = start_session(context, steps: [{:text, "hello back"}])
    :ok = Events.subscribe(parent.id, :internal)
    Troupe.send_input(parent.id, "hello")
    await_event(parent.id, :turn_ended, 10_000)

    before = Log.read_session(parent.id, context.state_dir)

    assert {:ok, child} =
             Troupe.fork_session(parent.id, config_overrides: overrides(context))

    on_exit(fn -> Troupe.stop_session(child.id) end)
    refute child.id == parent.id

    [forked | carried] = Log.read_session(child.id, context.state_dir)
    assert forked.type == "session_forked"
    assert forked.seq == 1
    assert forked.data["reason"] == "branch"
    assert forked.data["parent"]["session_id"] == parent.id
    assert forked.data["parent"]["seq"] == List.last(before).seq

    # The parent's events, in order, numbered on from the opening; then the resume.
    assert Enum.take(Enum.map(carried, & &1.type), length(before)) == Enum.map(before, & &1.type)

    assert Enum.map(Enum.take(carried, length(before)), & &1.seq) ==
             Enum.to_list(2..(length(before) + 1))

    assert "session_resumed" in Enum.map(carried, & &1.type)
    assert :ok = Event.verify(Log.read_session(child.id, context.state_dir))

    # The parent is as it was.
    assert Log.read_session(parent.id, context.state_dir) == before

    # A session of its own, not a branch, under the parent's profile.
    assert %{parent: nil, workspace: workspace} = Troupe.get_session(child.id)
    assert workspace == Troupe.get_session(parent.id).workspace

    # Its agent starts from the parent's conversation.
    :ok = Events.subscribe(child.id, :internal)
    Troupe.send_input(child.id, "go on")
    await_event(child.id, :turn_ended, 10_000)

    [request | _] = Fake.requests(Registry.fake(child.id))
    said = inspect(request.messages)
    assert said =~ "hello back"
    assert said =~ "go on"
  end

  test "a session the daemon does not have is not forked", context do
    assert {:error, :not_found} =
             Troupe.fork_session(Troupe.Session.generate_id(),
               config_overrides: overrides(context)
             )
  end

  defp overrides(context),
    do: [provider: "fake", auto_approve: true, model: "fake-model", state_dir: context.state_dir]
end
