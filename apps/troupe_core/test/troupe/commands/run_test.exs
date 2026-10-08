defmodule Troupe.Commands.RunTest do
  @moduledoc """
  Running a command a file defines (Decision 814): its prompt goes to the session as
  input, except that a workspace's command asks once before it is first sent while the
  session approves every tool call itself, showing what it sends. Who wrote it, whether
  `auto_approve` is on, whether the workspace is trusted, and what was answered before
  decide whether it asks.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Commands
  alias Troupe.Commands.Trust

  defp command(context, layer, body) do
    path =
      if layer == :project,
        do: Path.join(context.workspace, ".troupe/commands/review.md"),
        else: Path.join(context.base, "config/commands/review.md")

    %{name: "review", description: "", hint: nil, body: body, layer: layer, path: path}
  end

  defp run(context, session, command, arguments, opts \\ []) do
    Commands.run(
      session.id,
      command,
      arguments,
      Keyword.merge(
        [workspace: context.workspace, trusted: false, state_dir: context.state_dir],
        opts
      )
    )
  end

  defp answer(session, call_id, text), do: Troupe.answer(session.id, call_id, text)

  defp inputs(session), do: events_of_type(session.id, :user_input)

  test "a workspace's command asks before it is first sent, with what it sends; once sends it and remembers nothing",
       context do
    %{session: session} = start_session(context, steps: [{:text, "reviewed"}, {:text, "again"}])
    Troupe.subscribe(session.id)
    review = command(context, :project, "Review $ARGUMENTS and say what is wrong.")

    assert {:ok, {:asking, call_id}} =
             run(context, session, review, "the parser", command_id: "c-1")

    asked = await_event(session.id, :question_asked)
    assert asked.data["call_id"] == call_id
    assert asked.data["agent_path"] == ["root"]
    assert asked.data["preview"] == "Review the parser and say what is wrong."
    assert asked.data["question"] =~ "/review comes with this workspace"
    assert asked.data["question"] =~ "auto_approve is on"

    assert [%{"label" => "deny"}, %{"label" => "once"}, %{"label" => "allow"}] =
             asked.data["options"]

    assert inputs(session) == []

    answer(session, call_id, "once")
    input = await_event(session.id, :user_input)
    assert input.data["text"] == "Review the parser and say what is wrong."
    assert input.data["command_id"] == "c-1"

    # Once is this time only: the next run asks again, and nothing was written down.
    assert {:ok, {:asking, _again}} = run(context, session, review, "the lexer")
    refute File.exists?(Trust.path(context.state_dir))
  end

  test "allow is remembered for the command as its file reads, and an edit asks again", context do
    %{session: session} = start_session(context, steps: [{:text, "one"}, {:text, "two"}])
    Troupe.subscribe(session.id)
    review = command(context, :project, "Review the change.")

    {:ok, {:asking, call_id}} = run(context, session, review, "")
    await_event(session.id, :question_asked)
    answer(session, call_id, "allow")
    await_event(session.id, :user_input)

    assert Trust.approved?(context.state_dir, context.workspace, review)
    assert {:ok, :sent} = run(context, session, review, "")

    # The answer is kept beside the session's state, never in the repository.
    assert File.exists?(Trust.path(context.state_dir))
    refute File.exists?(Path.join(context.workspace, ".troupe/command-trust.json"))

    edited = %{review | body: "Delete the tests."}
    refute Trust.approved?(context.state_dir, context.workspace, edited)
    assert {:ok, {:asking, _}} = run(context, session, edited, "")
  end

  test "deny sends nothing and writes why, with how to run it later", context do
    %{session: session} = start_session(context)
    Troupe.subscribe(session.id)
    review = command(context, :project, "Review the change.")

    {:ok, {:asking, call_id}} = run(context, session, review, "", command_id: "c-2")
    await_event(session.id, :question_asked)
    answer(session, call_id, "deny")

    declined = await_event(session.id, :command_declined)
    assert declined.data["name"] == "review"
    assert declined.data["command_id"] == "c-2"
    assert declined.data["reason"] =~ "/review was not sent"
    assert declined.data["reason"] =~ "Run /review again to be asked again"
    assert inputs(session) == []
    refute Trust.approved?(context.state_dir, context.workspace, review)
  end

  test "a session nobody can answer in sends nothing, and says how it would run", context do
    %{session: session} = start_session(context, config_overrides: [approvals: :deny])
    Troupe.subscribe(session.id)

    {:ok, {:asking, _call_id}} =
      run(context, session, command(context, :project, "Review the change."), "")

    declined = await_event(session.id, :command_declined)
    assert declined.data["reason"] =~ "nobody can answer"
    assert declined.data["reason"] =~ "auto_approve off"
    assert inputs(session) == []
  end

  test "a person's own command, auto_approve off, or a trusted workspace sends without asking",
       context do
    %{session: session} = start_session(context, steps: [{:text, "a"}, {:text, "b"}])
    Troupe.subscribe(session.id)

    assert {:ok, :sent} = run(context, session, command(context, :user, "Mine."), "")
    await_event(session.id, :user_input)

    project = command(context, :project, "The team's.")
    assert {:ok, :sent} = run(context, session, project, "", trusted: true)
    await_event(session.id, :user_input)

    %{session: careful} = start_session(context, config_overrides: [auto_approve: false])
    assert {:ok, :sent} = run(context, careful, project, "")

    assert events_of_type(session.id, :question_asked) == []
    assert events_of_type(careful.id, :question_asked) == []
  end

  test "the answers are kept per checkout and per command", context do
    one = Path.join(context.base, "one")
    two = Path.join(context.base, "two")
    File.mkdir_p!(one)
    File.mkdir_p!(two)

    review = %{name: "review", body: "Review the change."}
    standup = %{name: "standup", body: "Say what changed."}

    assert :ok = Trust.approve(context.state_dir, one, review)
    assert :ok = Trust.approve(context.state_dir, one, standup)

    assert Trust.approved?(context.state_dir, one, review)
    assert Trust.approved?(context.state_dir, one, standup)
    refute Trust.approved?(context.state_dir, two, review)
    refute Trust.approved?(context.state_dir, one, %{review | body: "Review it differently."})
    assert Trust.fingerprint(review) =~ ~r/^sha256:[0-9a-f]{64}$/
  end
end
