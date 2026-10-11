defmodule Troupe.Protocol.ClientUpdateTest do
  @moduledoc """
  What a plane's version policy says to one client (Decision 868), read the same way by
  the plane judging and by the terminal and the daemon putting a refusal into words.
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.{ClientUpdate, Error}

  @policy %{recommended: "0.13.1-beta", minimum: "0.13.0-beta", blocked: ["0.13.2-beta"]}

  test "a client is the component its name says, and any other name is none" do
    assert ClientUpdate.component("troupe") == "tui"
    assert ClientUpdate.component("troupe-headless") == "tui"
    assert ClientUpdate.component("troupe-daemon") == "daemon"
    assert ClientUpdate.component("troupe-gui") == "desktop"
    assert ClientUpdate.component("troupe update") == nil
    assert ClientUpdate.component(nil) == nil
  end

  test "a version is judged as SemVer orders it, and a blocked one whatever its number" do
    assert ClientUpdate.judge(@policy, "0.12.9-beta") == {:refuse, :below_minimum}
    # A pre-release comes before its release, so 0.13.0 is past a minimum of 0.13.0-beta.
    assert ClientUpdate.judge(@policy, "0.13.0-beta") == {:ok, "suggest"}
    assert ClientUpdate.judge(@policy, "0.13.1-beta") == {:ok, "none"}
    assert ClientUpdate.judge(@policy, "0.13.2-beta") == {:refuse, :blocked}
    assert ClientUpdate.judge(@policy, "1.0.0") == {:ok, "none"}

    # A version nothing can place is held to the blocked list alone.
    assert ClientUpdate.judge(@policy, "dev") == {:ok, "none"}
    assert ClientUpdate.judge(%{"blocked" => ["dev"]}, "dev") == {:refuse, :blocked}
    assert ClientUpdate.judge(%{}, "0.1.0") == {:ok, "none"}
  end

  test "a refusal carries its fields and says them as one sentence, which says what to run" do
    data = ClientUpdate.refusal("tui", "0.12.0-beta", @policy, :below_minimum)

    assert data["minimum"] == "0.13.0-beta"
    assert data["run"] == "troupe update"
    refute data["blocked"]

    assert data["reason"] ==
             "This plane needs troupe 0.13.0-beta or later, and this is 0.12.0-beta: " <>
               "run troupe update, which installs 0.13.1-beta."

    blocked = ClientUpdate.refusal("daemon", "0.13.2-beta", @policy, :blocked)

    assert blocked["reason"] ==
             "This plane does not serve troupe-daemon 0.13.2-beta, which its administrators " <>
               "have blocked: run troupe update, which installs 0.13.1-beta."

    # The desktop app has no updater of its own yet, so nothing is named to run.
    desktop =
      ClientUpdate.refusal("desktop", "0.12.0-beta", %{minimum: "0.13.0-beta"}, :below_minimum)

    assert desktop["run"] == nil

    assert desktop["reason"] ==
             "This plane needs the desktop app 0.13.0-beta or later, and this is 0.12.0-beta: " <>
               "install a newer desktop app."
  end

  test "the sentence is the same from the fields as JSON delivered them" do
    data =
      "tui"
      |> ClientUpdate.refusal("0.12.0-beta", @policy, :below_minimum)
      |> Jason.encode!()
      |> Jason.decode!()

    assert ClientUpdate.sentence(data) == data["reason"]

    assert ClientUpdate.sentence(%{"reason" => "Ask your administrator."}) ==
             "Ask your administrator."
  end

  test "update_required is an error code of its own" do
    assert Error.new(:update_required, %{}).code == -32_016
    assert Error.token(-32_016) == :update_required
  end
end
