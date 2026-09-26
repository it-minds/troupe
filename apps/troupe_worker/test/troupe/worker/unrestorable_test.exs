defmodule Troupe.Worker.UnrestorableTest do
  @moduledoc "A tree that cannot be put back is said once, in words the plane parks a session on (Decision 661)."

  use ExUnit.Case, async: true

  alias Troupe.Protocol.Error
  alias Troupe.Worker.Plane.Commands
  alias Troupe.Worker.Session.Manager

  test "a gone workspace answers the plane's push as not_found/workspace_gone; anything else stays opaque" do
    assert %Error{message: "not_found", data: %{reason: "workspace_gone", detail: "/erased/ws"}} =
             Commands.activation_error({:not_a_directory, "/erased/ws"})

    assert %Error{message: "internal_error"} = Commands.activation_error({:unreadable_segment, "k", :enoent})
  end

  # A profile whose config does not load: what the plane and the person see is what to fix,
  # not `%Troupe.Config.Error{issues: [...]}`.
  test "a config that does not load is its message" do
    issue = %Troupe.Config.Issue{level: :error, source: "TROUPE_MAX_TURNS", message: "must be a whole number"}
    error = %Troupe.Config.Error{issues: [issue]}

    assert %Error{message: "internal_error", data: %{reason: reason}} = Commands.activation_error(error)
    assert reason == "the configuration did not load: TROUPE_MAX_TURNS: must be a whole number"
  end

  test "the manager reports a gone workspace to the plane, and nothing else" do
    assert %{
             "type" => "session.unrestorable",
             "session_id" => "s-1",
             "reason" => "workspace_gone",
             "detail" => "/erased/ws"
           } = Manager.unrestorable_report("s-1", {:not_a_directory, "/erased/ws"})

    assert Manager.unrestorable_report("s-1", {:stale_epoch, 2, 1}) == nil
    assert Manager.unrestorable_report("s-1", :timeout) == nil
  end
end
