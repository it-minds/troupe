defmodule Troupe.OnboardingNoticeTest do
  @moduledoc """
  The harness's `onboarding_suggested` (root Decision 827) is a line in the session's
  transcript, the harness's own sentence as it is, rather than the bare `type key=value`
  an unknown event is drawn as.
  """

  use ExUnit.Case, async: true

  alias Troupe.Remote.Translate
  alias Troupe.UI.TUI.Model

  @message "Other tools' files are here: `troupe onboard` would bring in 1 AGENTS.md and 2 " <>
             "rules as Troupe's own files. Run it in this workspace to see each as a diff and " <>
             "choose; nothing is written until you do."

  test "the notice is a line of the root's transcript, in the harness's words" do
    event = %{
      "type" => "onboarding_suggested",
      "seq" => 4,
      "agent" => ["root"],
      "ts" => "2026-10-10T09:00:00Z",
      "data" => %{
        "reasons" => ["first"],
        "message" => @message,
        "command" => "troupe onboard",
        "proposals" => %{"instructions" => 1, "rules" => 2}
      }
    }

    {events, _memory} = Translate.durable("s-1", event, Translate.memory())

    assert [%{type: :remote_note, data: %{text: @message}}] =
             Enum.filter(events, &(&1.type == :remote_note))

    model = Model.rebuild("s-1", "/w", events)
    assert {:system, @message} in model.windows["root"].agents["root"].transcript
  end
end
