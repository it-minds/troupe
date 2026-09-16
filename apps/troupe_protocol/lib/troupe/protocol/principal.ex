defmodule Troupe.Protocol.Principal do
  @moduledoc """
  On whose authority, and by what: two halves that are usually equal and sometimes not.

      %{"subject" => "ada@example.test", "actor" => "svc:engineering/nightly-triage"}

  `subject` is whose authority the work is done under — whose credential goes out, whose
  cap it counts against, who would be asked about it. `actor` is the thing that actually
  did it: a person at a keyboard, or a service principal firing at four in the morning.

  ## Why both are always written

  Where a person is acting for themselves the two are equal, and they are written
  anyway. A field that is omitted when it matches is a field a reader cannot interpret:
  they have to know whether it is absent because the two were the same or because
  nobody wrote it that day, and those are not distinguishable after the fact. Writing
  both costs a few bytes in a log that is already compressed and removes a whole class
  of "it depends when this was recorded".

  ## The one case worth the trouble

  A person-mode MCP server in a session a trigger started: the credential is a person's,
  the session is a principal's, and the call goes out as one on behalf of the other.
  A single `identity` field had to pick, and whichever it picked the other was invisible.
  """

  @enforce_keys [:subject, :actor]
  defstruct [:subject, :actor]

  @type t :: %__MODULE__{subject: String.t(), actor: String.t()}

  @doc """
  A person acting for themselves: both halves the same.

  The common case, and the reason this is a function rather than a convention — writing
  `%Principal{subject: s, actor: s}` by hand at twenty call sites is twenty chances to
  write it twice with different values.
  """
  @spec of(String.t()) :: t()
  def of(subject) when is_binary(subject), do: %__MODULE__{subject: subject, actor: subject}

  @doc "One acting on another's authority: a principal with a person's credential."
  @spec of(String.t(), String.t()) :: t()
  def of(subject, actor) when is_binary(subject) and is_binary(actor) do
    %__MODULE__{subject: subject, actor: actor}
  end

  @doc "Whether the two halves differ, which is what makes a call *delegated*."
  @spec delegated?(t()) :: boolean()
  def delegated?(%__MODULE__{subject: subject, actor: actor}), do: subject != actor

  @doc "For a log, an audit row or a panel."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = principal) do
    %{"subject" => principal.subject, "actor" => principal.actor}
  end

  @doc """
  Back from a stored map, tolerating what was written before there were two halves.

  A log is append-only and outlives its schema: an event recorded when `identity` was one
  string is read as a principal acting for itself, which is what it meant.
  """
  @spec from_json(map() | String.t() | nil) :: t() | nil
  def from_json(%{"subject" => subject, "actor" => actor})
      when is_binary(subject) and is_binary(actor) do
    of(subject, actor)
  end

  def from_json(%{"subject" => subject}) when is_binary(subject), do: of(subject)
  def from_json(subject) when is_binary(subject), do: of(subject)
  def from_json(_other), do: nil
end
