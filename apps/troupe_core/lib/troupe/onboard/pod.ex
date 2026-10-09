defmodule Troupe.Onboard.Pod do
  @moduledoc """
  Onboarding does not run on a pod (Decision 826).

  Onboarding writes Troupe's own files from other tools' — into a repository's
  `.troupe/` and a person's config directory — and on a pod both are the wrong place. The
  working copy is a clone a session works in, whose `.troupe/agents/` and
  `.troupe/skills/` the bundle beats there unless the profile allows them, and the config
  directory is the pod's, read by every session it runs. A repository is onboarded on
  somebody's own machine, the result reviewed and committed, and a pod reads what was
  committed.

  `troupe onboard` and the onboarding tool both ask `refusal/1` before they read or write
  anything, so the two cannot come to disagree about what a pod is.
  """

  @refusal "Onboarding runs on your own machine, not on a pod: run `troupe onboard` in " <>
             "your checkout, commit what it writes, and sessions here read it from the repository."

  @doc """
  The sentence onboarding answers with where it may not run, or `nil` where it may.

  The onboarding tool passes its session's id, and a session on a pod — `kind` `team` in
  its `session_created` — is refused. The command line passes `nil`, and is refused on a
  machine a worker runs on, which the operator and a host's service both mark with
  `TROUPE_WORKER_AUTOSTART=true`; a command a session's shell runs there inherits it.
  """
  @spec refusal(String.t() | nil) :: String.t() | nil
  def refusal(session_id \\ nil) do
    if pod_session?(session_id) or worker?(), do: @refusal
  end

  @doc "Whether onboarding may run here: `refusal/1` is `nil`."
  @spec allowed?(String.t() | nil) :: boolean()
  def allowed?(session_id \\ nil), do: refusal(session_id) == nil

  defp pod_session?(nil), do: false

  defp pod_session?(session_id) do
    match?(%{kind: "team"}, Troupe.get_session(session_id))
  catch
    # No index to ask is a process with no sessions in it, which is not a pod's.
    :exit, _ -> false
  end

  defp worker?, do: System.get_env("TROUPE_WORKER_AUTOSTART") == "true"
end
