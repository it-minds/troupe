defmodule Troupe.Session.OrganisationTest do
  @moduledoc """
  A change to the organisation's document reaches a session already running (#657): the
  session is resolved again, and its agent takes the new configuration as its next turn
  begins, never during one, and says so in a line. What was set up as the session started
  is named apart, and the same document again says nothing. Against a copy of the plane's
  document written by the test, as the daemon keeps one.
  """

  # The document's path is the application environment's, which is the whole VM's: a test
  # that moves it runs alone.
  use Troupe.SessionCase, async: false

  alias Troupe.Config.Org
  alias Troupe.LLM.Fake
  alias Troupe.Session.Organisation

  @plane "https://plane.example.test"

  setup context do
    previous = Application.get_env(:troupe_core, :organisation)
    cache = Path.join(context.base, "organisation.json")

    Application.put_env(:troupe_core, :organisation,
      managed_path: Path.join(context.base, "managed.yaml"),
      cache_path: cache,
      keys_path: Path.join(context.base, "plane-keys.json")
    )

    on_exit(fn -> Application.put_env(:troupe_core, :organisation, previous) end)
    Map.put(context, :cache, cache)
  end

  defp keep(context, enforced) do
    {:ok, _kept} = Org.save(@plane, %{"defaults" => %{}, "enforced" => enforced}, context.cache)
  end

  defp turn(sid, text) do
    Troupe.send_input(sid, text)
    await_state(sid, [:idle], 10_000)
  end

  test "a limit the organisation enforces reaches a running session at its next turn, said in a line",
       context do
    keep(context, %{"max_tokens" => 4000})

    %{session: session, fake: fake} =
      start_session(context, steps: [{:text, "one"}, {:text, "two"}, {:text, "three"}])

    sid = session.id
    :ok = Troupe.subscribe(sid)
    turn(sid, "first")
    assert [%{max_tokens: 4000}] = Fake.requests(fake)

    keep(context, %{"max_tokens" => 1000, "approvals" => "deny"})
    assert {:ok, ["approvals", "max_tokens"]} = Organisation.reconfigure(sid)

    # Nothing is taken until a turn begins: what the session explains already says it.
    assert [] = events_of_type(sid, "config_note")
    assert Troupe.Session.resolved(sid).layers.enforced[["max_tokens"]].value == 1000

    turn(sid, "second")
    assert [_first, %{max_tokens: 1000}] = Fake.requests(fake)

    assert [%{agent: ["root"], data: data}] = events_of_type(sid, "config_note")

    assert data == %{
             "key" => "organisation",
             "message" =>
               "Your organisation's settings changed: max_tokens holds from this turn; " <>
                 "approvals when the session is started again."
           }

    # The same document again: nothing to take, nothing said.
    assert {:ok, []} = Organisation.reconfigure(sid)
    turn(sid, "third")
    assert [_one_line] = events_of_type(sid, "config_note")
    assert [_, _, %{max_tokens: 1000}] = Fake.requests(fake)
  end

  test "every session running here is resolved again, each once", context do
    %{session: one} = start_session(context, steps: [{:text, "one"}])
    %{session: two} = start_session(context, steps: [{:text, "two"}])

    keep(context, %{"max_tokens" => 2000})
    assert Organisation.reconfigure_all() >= 2
    assert {:ok, []} = Organisation.reconfigure(one.id)

    assert Organisation.given(one.id).keys == ["max_tokens"]
    assert Organisation.given(two.id).keys == ["max_tokens"]
    assert {:error, :no_session} = Organisation.reconfigure("no-such-session")
  end
end
