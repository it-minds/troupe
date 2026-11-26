defmodule Troupe.Proposals do
  @moduledoc """
  Where a session's proposals are checked and a `never` is kept (#1208): the host's.

  The harness proposes something to a session's owner (`Troupe.Session.Proposals`) only
  where the host installed somewhere to ask first, because whether it may is not the
  core's to know: a pod asks the plane over its control link, which reads the session's
  team, its owner and what they said before, and answers whether to propose and how a yes
  would be carried out. A host that installs nothing, as a person's machine does, has no
  scheduler to offer, and no proposal is made there.

  Two functions, installed together:

    * `check`, given the session id and the proposal (`kind`, `key`, `draft`), answers
      `{:ok, %{"propose" => true, "mode" => ..., "draft" => ...}}` with what the plane
      adds to the draft, or `{:ok, %{"propose" => false, "reason" => ...}}`, or an error;
    * `never`, given the session id, the proposal's `kind` and `key`, keeps the owner's
      "never for this" where the next session of theirs is checked against it.
  """

  @typedoc "What the host answers about one proposal."
  @type answer :: %{String.t() => term()}

  @type check :: (String.t(), map() -> {:ok, answer()} | {:error, term()})
  @type never :: (String.t(), String.t(), String.t() -> :ok | {:error, term()})

  @doc "Install the host's two functions."
  @spec install(check(), never()) :: :ok
  def install(check, never) when is_function(check, 2) and is_function(never, 3),
    do: Application.put_env(:troupe_core, :proposals, %{check: check, never: never})

  @doc "Take them away again, as a test that installed them does."
  @spec uninstall() :: :ok
  def uninstall, do: Application.delete_env(:troupe_core, :proposals)

  @doc "Whether this host installed anywhere to ask: whether proposals are made here at all."
  @spec proposes?() :: boolean()
  def proposes?, do: match?(%{check: _, never: _}, Application.get_env(:troupe_core, :proposals))

  @doc "Ask the host whether to make `proposal` in `session_id`, and how."
  @spec check(String.t(), map()) :: {:ok, answer()} | {:error, term()}
  def check(session_id, proposal) do
    case Application.get_env(:troupe_core, :proposals) do
      %{check: check} -> check.(session_id, proposal)
      _none -> {:ok, %{"propose" => false, "reason" => "nothing here schedules"}}
    end
  end

  @doc "Keep the owner's never for `kind` and `key`, asked from `session_id`."
  @spec never(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def never(session_id, kind, key) do
    case Application.get_env(:troupe_core, :proposals) do
      %{never: never} -> never.(session_id, kind, key)
      _none -> {:error, "nothing here keeps it"}
    end
  end
end
