defmodule Troupe.Agent.IdentifyTest do
  @moduledoc """
  Which client a session's model calls name, and whether they name Troupe at all
  (Decision 787): the session's own `client`, and `identify` from the config ladder, on
  every request an agent makes. What the adapters do with the two is
  `Troupe.LLM.IdentifyTest`'s.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Config

  test "every call carries the session's client, and identifies unless the config says not to",
       context do
    %{session: session, fake: fake} =
      start_session(context, steps: [{:text, "one"}], config_overrides: [client: "desktop"])

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "go")
    await_state(session.id, [:idle])

    assert [%{client: "desktop", identify: true}] = Fake.requests(fake)
  end

  test "identify: false reaches the request", context do
    %{session: session, fake: fake} =
      start_session(context,
        steps: [{:text, "one"}],
        config_overrides: [client: "tui", identify: false]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "go")
    await_state(session.id, [:idle])

    assert [%{client: "tui", identify: false}] = Fake.requests(fake)
  end

  describe "the key" do
    setup context do
      user = Path.join(context.base, "config.yaml")
      File.mkdir_p!(Path.join(context.workspace, ".troupe"))
      Map.put(context, :user, user)
    end

    test "is on unless a file turns it off", context do
      File.write!(context.user, "provider: fake\n")

      assert {:ok, %Config{identify: true}, _layers} =
               Config.resolve(context.workspace, [], user_path: context.user)

      File.write!(context.user, "provider: fake\nidentify: false\n")

      assert {:ok, %Config{identify: false}, _layers} =
               Config.resolve(context.workspace, [], user_path: context.user)
    end

    test "a project's file turns it off only in a workspace the user trusts", context do
      File.write!(Path.join(context.workspace, ".troupe/config.yaml"), "identify: false\n")

      File.write!(context.user, "provider: fake\n")

      assert {:ok, %Config{identify: true, warnings: warnings}, _layers} =
               Config.resolve(context.workspace, [], user_path: context.user)

      assert Enum.any?(warnings, &(&1 =~ "identify"))

      File.write!(
        context.user,
        "provider: fake\ntrusted_workspaces:\n  - #{Jason.encode!(context.workspace)}\n"
      )

      assert {:ok, %Config{identify: false}, _layers} =
               Config.resolve(context.workspace, [], user_path: context.user)
    end
  end
end
