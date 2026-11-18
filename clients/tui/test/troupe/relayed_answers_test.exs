defmodule Troupe.RelayedAnswersTest do
  @moduledoc """
  A laptop's session steered from the terminal through the plane (#932): its approvals are
  answered once from here only where the laptop's daemon says `relayed` and not
  `relayed_allow_session`, as a daemon from before it does. One that takes an answer for
  the rest of the session from there is answered as any other session, `a` and all.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers, only: [eventually: 2]

  alias Troupe.FakeRemote
  alias Troupe.Remote.Worker

  @moduletag :remote

  defp attached(capabilities) do
    {remote, url} =
      start_remote!(
        sessions: [FakeRemote.session(id: "s-laptop", profile: "code")],
        capabilities: capabilities
      )

    origin = connect!(remote, url)
    sid = attach!(origin, "s-laptop")
    eventually(fn -> Worker.status(sid).up? end, 10_000)
    sid
  end

  test "a laptop's daemon from before answers once from here" do
    sid = attached(%{"relayed" => true})
    assert Worker.status(sid).relayed?
  end

  test "a laptop that takes an answer for the session from there is answered as any session" do
    sid = attached(%{"relayed" => true, "relayed_allow_session" => true})
    refute Worker.status(sid).relayed?
  end
end
