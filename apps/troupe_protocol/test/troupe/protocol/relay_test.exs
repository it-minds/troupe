defmodule Troupe.Protocol.RelayTest do
  @moduledoc """
  The one table both ends of a relayed session check each message against (#58, Decision
  921): the session's own steering and reading, at the role each end holds the person to,
  and nothing of the laptop.
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.Relay

  @sid "20261018T120000-abcdef"

  test "a control role steers the session: prompt, answers, cancel, the agent" do
    for method <- ~w(input.send approval.respond question.answer turn.cancel profile.switch) do
      assert :ok == Relay.check(method, %{"session_id" => @sid, "decision" => "allow"}, @sid, "control"),
             method
    end
  end

  test "an observe role reads and is refused steering, naming the scope" do
    assert :ok == Relay.check("subscribe", %{"topic" => "session:" <> @sid}, @sid, "observe")
    assert :ok == Relay.check("agents.list", %{"session_id" => @sid}, @sid, "observe")

    assert {:error, %{message: "forbidden", data: %{required_scope: "control"}}} =
             Relay.check("input.send", %{"session_id" => @sid}, @sid, "observe")
  end

  test "nothing of the laptop, and no other session, is reached" do
    for method <- ~w(fs.read fs.upload shell.run tools.register session.create config.set mcp.call
                     identity.link remote.offer daemon.stop) do
      assert {:error, %{message: "forbidden"}} = Relay.check(method, %{"session_id" => @sid}, @sid, "control"),
             method
    end

    assert {:error, %{data: %{field: "session_id"}}} =
             Relay.check("input.send", %{"session_id" => "20261018T120000-zzzzzz"}, @sid, "control")

    assert {:error, %{data: %{field: "topic"}}} = Relay.check("subscribe", %{"topic" => "fleet"}, @sid, "control")

    assert {:error, %{data: %{field: "workspace"}}} =
             Relay.check("agents.list", %{"workspace" => "/home"}, @sid, "control")
  end

  test "an approval from another device is for the one call" do
    assert {:error, %{data: %{field: "decision"}}} =
             Relay.check("approval.respond", %{"session_id" => @sid, "decision" => "allow_session"}, @sid, "control")
  end

  test "the narrower of two roles holds, and none is none" do
    assert Relay.narrower("control", "control") == "control"
    assert Relay.narrower("control", "observe") == "observe"
    assert Relay.narrower("observe", "control") == "observe"
    assert Relay.narrower("control", nil) == nil
  end
end
