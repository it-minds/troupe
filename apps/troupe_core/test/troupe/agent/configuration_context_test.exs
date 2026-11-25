defmodule Troupe.Agent.ConfigurationContextTest do
  @moduledoc """
  Issue #1177: a session whose configuration moved to another bundle version (raised by its
  owner, or its version retired) tells its root agent so in the turn context, once, as the
  other sections are; a restart after it does not say it again.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.LLM.{Fake, Message, Text}
  alias Troupe.Session.Log

  @moved %{
    version: 14,
    hash: nil,
    channel: "stable",
    dir: nil,
    upgraded_from: 12,
    upgrade_reason: "raised",
    upgraded_by: "ana-subject",
    upgraded_by_name: "Ana"
  }

  test "a session that never moved sends no configuration section", context do
    %{session: session} =
      start_session(context,
        steps: [{:text, "one"}],
        bundle: %{@moved | upgraded_from: nil, upgrade_reason: nil, upgraded_by_name: nil}
      )

    sid = session.id
    Troupe.subscribe(sid)
    turn(sid, "first")

    refute Enum.any?(sections(sid), &("configuration" in &1))
  end

  test "the root is told its configuration moved at the first turn after the move, and never again",
       context do
    %{session: session} = start_session(context, steps: [{:text, "one"}])
    sid = session.id
    Troupe.subscribe(sid)
    turn(sid, "first")
    :ok = stopped(sid)
    drain()

    # Woken on the raised version, as a pod restarts the tree: the pin says it moved, and
    # the move is written after the tree is up.
    raised = start_supervised!({Fake, steps: [{:text, "two"}, {:text, "three"}]}, id: :raised)
    resume(context, sid, raised, @moved)

    {:ok, _seq} =
      Log.append(sid, ["root"], :config_upgraded, %{
        "channel" => "stable",
        "from" => 12,
        "to" => 14,
        "reason" => "raised",
        "by" => "ana-subject",
        "by_name" => "Ana"
      })

    turn(sid, "second")
    turn(sid, "third")

    [second, third] = Fake.requests(raised)
    told = turn_context(second, length(second.messages) - 1)
    assert told =~ "Your configuration moved from v12 to v14 (raised by Ana)"
    assert told =~ "tools, skills and servers are the new version's"
    refute turn_context(third, length(third.messages) - 1) =~ "configuration moved"

    # Once: the first turn before the move said nothing of it, the one after it did.
    assert sections(sid) |> Enum.filter(&("configuration" in &1)) |> length() == 1

    # A later wake on the same version folds the move and what was sent, and says nothing.
    :ok = stopped(sid)
    drain()
    later = start_supervised!({Fake, steps: [{:text, "four"}]}, id: :later)
    resume(context, sid, later, %{@moved | upgraded_from: nil, upgrade_reason: nil, upgraded_by_name: nil})
    turn(sid, "fourth")

    [fourth] = Fake.requests(later)
    refute turn_context(fourth, length(fourth.messages) - 1) =~ "configuration moved"
    assert sections(sid) |> Enum.filter(&("configuration" in &1)) |> length() == 1
  end

  # Issue #1207: a pod session's GitHub repositories, each where its clone is, said in the
  # same section when they move, and folded so a restart does not say them again.
  test "the root is told the repositories it holds, and again when one is attached or taken off",
       context do
    %{session: session, fake: fake} =
      start_session(context, steps: [{:text, "one"}, {:text, "two"}, {:text, "three"}])

    sid = session.id
    Troupe.subscribe(sid)
    widgets = %{"repository" => "example-org/widgets", "path" => ".", "ref" => "main"}
    gadgets = %{"repository" => "example-org/gadgets", "path" => "example-org/gadgets", "ref" => nil}

    :ok =
      Troupe.set_repositories(sid, %{
        "action" => "attached",
        "repository" => "example-org/widgets",
        "path" => ".",
        "repositories" => [widgets]
      })

    turn(sid, "first")

    :ok =
      Troupe.set_repositories(
        sid,
        %{
          "action" => "attached",
          "repository" => "example-org/gadgets",
          "path" => "example-org/gadgets",
          "by_name" => "Ada",
          "repositories" => [widgets, gadgets]
        },
        Troupe.Protocol.Event.Actor.user("ada-subject", "Ada")
      )

    assert Troupe.repositories(sid) == [widgets, gadgets]
    turn(sid, "second")
    turn(sid, "third")

    [first, second, third] = Fake.requests(fake)
    told = turn_context(first, length(first.messages) - 1)
    assert told =~ "The GitHub repositories this session holds, each a clone in the workspace:"
    assert told =~ "- example-org/widgets: at the workspace's root, branch main"

    again = turn_context(second, length(second.messages) - 1)
    assert again =~ "example-org/gadgets was attached by Ada."
    assert again =~ "- example-org/gadgets: in example-org/gadgets/, its default branch"
    assert again =~ "name it as repository where there is more than one"
    refute turn_context(third, length(third.messages) - 1) =~ "GitHub repositories"

    [changed | _] = events_of_type(sid, :session_repository_changed) |> Enum.reverse()
    assert changed.actor.subject == "ada-subject"
    assert changed.data["repositories"] == [widgets, gadgets]
  end

  defp resume(context, sid, fake, bundle) do
    {:ok, _} =
      Troupe.resume(sid,
        workspace: context.workspace,
        fake: fake,
        bundle: bundle,
        config_overrides: [provider: "fake", auto_approve: true, state_dir: context.state_dir]
      )

    on_exit(fn -> Troupe.stop_session(sid) end)
    Troupe.subscribe(sid)
  end

  defp sections(sid) do
    for %{data: data} <- events_of_type(sid, :llm_request), do: data["turn_context"] || []
  end

  defp turn(sid, text) do
    Troupe.send_input(sid, text)
    await_event(sid, :turn_ended, 10_000)
    await_state(sid, [:idle], 10_000)
  end

  defp turn_context(request, index) do
    case Enum.at(request.messages, index) do
      %Message{role: :user, content: content} ->
        for %Text{text: "<turn_context>" <> _ = text} <- content, into: "", do: text

      _other ->
        ""
    end
  end

  defp drain do
    receive do
      {:troupe_event, _sid, _event} -> drain()
    after
      0 -> :ok
    end
  end

  defp stopped(session_id) do
    :ok = Troupe.stop_session(session_id)
    wait_for_release(session_id, 200)
  end

  defp wait_for_release(_session_id, 0), do: :ok

  defp wait_for_release(session_id, attempts) do
    if Troupe.Registry.whereis({:session, session_id}) ||
         Troupe.Registry.whereis({:log, session_id}) do
      Process.sleep(5)
      wait_for_release(session_id, attempts - 1)
    else
      :ok
    end
  end
end
