defmodule Troupe.LLM.Request do
  @moduledoc """
  A provider-neutral LLM request.

  `reasoning_effort` is what the *agent* asks for (from its definition); `nil`
  means "whatever the provider config says for this model". Adapters resolve the
  two with `Troupe.LLM.Provider.effort/2`.

  `cache` is what the adapter needs to place prompt-cache breakpoints, and is the
  only place they are ever expressed: `ttl` is the lifetime to ask for and
  `previous` the index of the message the *last* request put a breakpoint on, so
  a turn that appended a lot of content still has a read point inside the
  provider's lookback window. Markers are never stored in the conversation —
  a request may carry at most four.
  """

  @type t :: %__MODULE__{
          model: String.t(),
          system: String.t(),
          messages: [Troupe.LLM.Message.t()],
          tools: [map()],
          max_tokens: pos_integer(),
          reasoning_effort: String.t() | nil,
          agent_path: String.t(),
          session_id: String.t(),
          purpose: :turn | :compaction,
          cache: %{ttl: String.t(), previous: non_neg_integer() | nil} | nil
        }

  defstruct model: "",
            system: "",
            messages: [],
            tools: [],
            max_tokens: 8192,
            reasoning_effort: nil,
            agent_path: "",
            session_id: "",
            purpose: :turn,
            cache: nil
end
