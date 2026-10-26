defmodule Troupe.LocalOnly do
  @moduledoc """
  Whether a session is under its client's *Local only*: the client promised its person that
  nothing of what they do there reaches a plane, and the host keeps that promise for the
  session. Which client said so, and which sessions are theirs, is the daemon's to know
  (`Troupe.Gateway.LocalOnly`), so the host installs the question, as it installs where an
  agent's entry for the person's memory goes (`Troupe.UserMemory`). A host that installs
  nothing (a pod, a test) has no session under it.

  What a session does with it here is say so: the first `instructions_loaded` after it is
  put under Local only carries `local_only`, a sentence that it reads the memory this machine
  already holds and that nothing of it goes to the plane.
  """

  @doc "Whether `session_id` is under Local only, by the host's answer."
  @spec session?(String.t() | nil) :: boolean()
  def session?(session_id) when is_binary(session_id) do
    case Application.get_env(:troupe_core, :local_only) do
      fun when is_function(fun, 1) -> fun.(session_id) == true
      _none -> false
    end
  end

  def session?(_none), do: false

  @doc "Install `fun` as how this host says whether a session is under Local only."
  @spec install((String.t() -> boolean())) :: :ok
  def install(fun) when is_function(fun, 1),
    do: Application.put_env(:troupe_core, :local_only, fun)

  @doc "What `instructions_loaded` says, once, of a session under Local only."
  @spec line() :: String.t()
  def line do
    "Local only: this session reads the organisation's and your own memory as this machine " <>
      "last fetched them, and nothing of it goes to the plane; an agent's remember with " <>
      "level me is refused"
  end
end
