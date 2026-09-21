defmodule Troupe.Event do
  @moduledoc """
  One session event. Persisted events come from `Troupe.Session.Log`; transient
  ones (`llm_delta`, `agent_state`, `notice`) are published directly and never
  written to disk.
  """

  @type t :: %__MODULE__{
          session_id: String.t(),
          seq: non_neg_integer() | nil,
          ts: integer(),
          agent_path: String.t(),
          type: atom(),
          data: map(),
          transient?: boolean()
        }

  @enforce_keys [:session_id, :agent_path, :type, :data]
  defstruct [:session_id, :seq, :ts, :agent_path, :type, data: %{}, transient?: false]

  @doc "Builds a transient (never persisted) event."
  @spec transient(String.t(), String.t(), atom(), map()) :: t()
  def transient(session_id, agent_path, type, data) when is_atom(type) and is_map(data) do
    %__MODULE__{
      session_id: session_id,
      agent_path: agent_path,
      type: type,
      data: data,
      ts: System.system_time(:millisecond),
      transient?: true
    }
  end
end
