defmodule Troupe.LLM.Request do
  @moduledoc """
  A provider-neutral LLM request.

  `reasoning_effort` is what the *agent* asks for (from its definition); `nil`
  means "whatever the provider config says for this model". Adapters resolve the
  two with `Troupe.LLM.Provider.effort/2`.
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
          purpose: :turn | :compaction
        }

  defstruct model: "",
            system: "",
            messages: [],
            tools: [],
            max_tokens: 8192,
            reasoning_effort: nil,
            agent_path: "",
            session_id: "",
            purpose: :turn
end
