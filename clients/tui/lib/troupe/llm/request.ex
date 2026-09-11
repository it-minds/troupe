defmodule Troupe.LLM.Request do
  @moduledoc "A provider-neutral LLM request."

  @type t :: %__MODULE__{
          model: String.t(),
          system: String.t(),
          messages: [Troupe.LLM.Message.t()],
          tools: [map()],
          max_tokens: pos_integer(),
          agent_path: String.t(),
          session_id: String.t(),
          purpose: :turn | :compaction
        }

  defstruct model: "",
            system: "",
            messages: [],
            tools: [],
            max_tokens: 8192,
            agent_path: "",
            session_id: "",
            purpose: :turn
end
