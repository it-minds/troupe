defmodule Troupe.Onboard.PodTest do
  @moduledoc """
  Onboarding refuses on a pod, with a sentence (Decision 826): asked of a session, a team
  session is refused; asked of the machine, a worker's is.

  `async: false` because the machine's answer is an environment variable.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.Onboard.Pod

  setup do
    previous = System.get_env("TROUPE_WORKER_AUTOSTART")
    System.delete_env("TROUPE_WORKER_AUTOSTART")

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_WORKER_AUTOSTART", previous),
        else: System.delete_env("TROUPE_WORKER_AUTOSTART")
    end)
  end

  test "a session on a pod is refused, saying where to onboard instead", context do
    %{session: session} = start_session(context, kind: :team)

    refute Pod.allowed?(session.id)
    assert Pod.refusal(session.id) =~ "Onboarding runs on your own machine, not on a pod"
    assert Pod.refusal(session.id) =~ "troupe onboard"
  end

  test "a local session and a laptop's command line may onboard", context do
    %{session: session} = start_session(context)

    assert Pod.refusal(session.id) == nil
    assert Pod.allowed?(session.id)
    assert Pod.refusal() == nil
    assert Pod.refusal("20261009T000000-unknown") == nil
  end

  test "on a worker's machine nothing onboards, a local session's tool included", context do
    %{session: session} = start_session(context)
    System.put_env("TROUPE_WORKER_AUTOSTART", "true")

    assert Pod.refusal() =~ "not on a pod"
    refute Pod.allowed?(session.id)
  end
end
