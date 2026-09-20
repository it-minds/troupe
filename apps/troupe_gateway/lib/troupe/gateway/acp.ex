defmodule Troupe.Gateway.ACP do
  @moduledoc """
  The Agent Client Protocol, on the socket that already exists.

  An editor that speaks ACP drives a Troupe session. Not a second port, not a second
  authentication path, not a second implementation of a session — an adapter that maps
  ACP's four moving parts onto the ones underneath:

  | ACP | Troupe |
  | --- | --- |
  | a session, and streaming updates | a session, and `subscribe` at `detail` |
  | a permission-gated tool call | the approval flow, *allow always* included |
  | client filesystem and terminal | the mount table and `ClientTools` |
  | `session/cancel` | `turn.cancel` |

  ## Which protocol a connection is speaking is decided once, by what the client sent

  ACP's `initialize` carries `protocolVersion` and `clientCapabilities`; Troupe's carries
  `protocol_version` and `client_info`. The casing is the discriminator, and it is a good
  one because it is not a flag either side can get wrong by omission: a client that sent
  neither is refused as Troupe's own, which is what it was before ACP existed.

  What it is *not* is a second door. The connection has already authenticated by the time
  this is asked — socket permissions on Unix, a token from the discovery file on TCP and
  WebSocket — so an ACP client gets exactly the scopes that connection was going to get.
  There is no ACP authentication method, which is why `authMethods` comes back empty: the
  socket said who this is before ACP was mentioned.

  ## Two things ACP does not have, and Troupe does not give up for it

  **The durable log stays the record.** ACP's `session/update` is a notification with no
  sequence and no replay; Troupe's log has both. So updates are *rendered from* the event
  stream rather than replacing it, and an ACP client that misses one has missed a
  notification rather than a fact.

  **A session is not its client's process.** ACP was designed for an agent subprocess that
  dies with the editor. Here the session is on the other side of a socket and outlives
  every client attached to it — so `session/cancel` cancels a turn, `session/close` detaches
  this connection, and neither ends the session. An editor that is killed mid-turn leaves
  the turn running, and the next client to attach sees all of it.
  """

  alias Troupe.Gateway.Dispatch
  alias Troupe.Protocol.{Error, Event}

  @typedoc "What this adapter knows about one ACP client between its requests."
  @type state :: %{
          required(:sessions) => %{String.t() => map()},
          optional(:client_capabilities) => map()
        }

  # ACP versions are integers. One is what exists; a client asking for more is answered
  # with what this supports, which the spec says is the agent's job rather than a refusal.
  @version 1

  # Everything this adapter turns into something underneath. A method outside this list is
  # `method_not_found`, which is how an editor discovers a capability is missing rather
  # than by a call that silently does nothing.
  @methods ~w(
    initialize authenticate session/new session/prompt session/cancel session/close
  )

  @doc "The ACP protocol version this speaks."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Every ACP method this adapter answers."
  @spec methods() :: [String.t()]
  def methods, do: @methods

  @doc """
  Whether an `initialize` frame announces ACP.

  On the camelCase key, and deliberately not on a field a client could be asked to add: an
  editor that already speaks ACP sends this without being told anything about Troupe, which
  is the whole point of adopting a protocol somebody else designed.
  """
  @spec announced?(map()) :: boolean()
  def announced?(params) when is_map(params) do
    Map.has_key?(params, "protocolVersion") or Map.has_key?(params, "clientCapabilities")
  end

  def announced?(_params), do: false

  @doc "An empty adapter state, for a connection that has just chosen ACP."
  @spec new(map()) :: state()
  def new(params) do
    %{sessions: %{}, client_capabilities: Map.get(params, "clientCapabilities", %{})}
  end

  @doc """
  The answer to ACP's `initialize`.

  `authMethods` is empty on purpose and is not an oversight: this connection authenticated
  before ACP was mentioned, so there is nothing for an editor to authenticate *with* and
  offering a method would invite a round trip that can only fail.
  """
  @spec initialize(map()) :: map()
  def initialize(_params) do
    %{
      "protocolVersion" => @version,
      "agentInfo" => %{"name" => "troupe", "version" => Troupe.Protocol.version()},
      "authMethods" => [],
      "agentCapabilities" => %{
        # No `loadSession`: replaying a whole conversation as notifications is what
        # `subscribe` with `from_seq` does properly, and claiming it here would promise an
        # ACP client something weaker than the thing it is sitting on.
        "loadSession" => false,
        "promptCapabilities" => %{
          "image" => false,
          "audio" => false,
          "embeddedContext" => false
        },
        "mcpCapabilities" => %{"http" => false, "sse" => false},
        "sessionCapabilities" => %{}
      }
    }
  end

  @doc """
  Translate one ACP request into what it means underneath.

  Returns `{:dispatch, method, params}` for the ones that are a Troupe command wearing
  different names — which is most of them, and is the evidence that this is an adapter —
  or `{:reply, result}` where ACP asks something the connection can answer by itself.
  """
  @spec translate(String.t(), map(), state()) ::
          {:dispatch, String.t(), map()} | {:reply, map()} | {:error, Error.t()}
  def translate("initialize", params, _state), do: {:reply, initialize(params)}

  # There is nothing to authenticate. Answering rather than refusing, because an editor
  # that calls this has been told `authMethods` is empty and is being thorough.
  def translate("authenticate", _params, _state), do: {:reply, %{}}

  def translate("session/new", params, _state) do
    with {:ok, cwd} <- absolute(params, "cwd") do
      {:dispatch, "session.create",
       %{
         "command_id" => command_id(),
         "workspace" => cwd,
         # An ACP client is opening a session on this machine, and the worktree question is
         # Troupe's rather than ACP's. `auto` is what a person gets from the TUI.
         "worktree" => "auto"
       }}
    end
  end

  def translate("session/prompt", params, _state) do
    with {:ok, session_id} <- required(params, "sessionId"),
         {:ok, text} <- prompt_text(params) do
      {:dispatch, "input.send",
       %{"command_id" => command_id(), "session_id" => session_id, "text" => text}}
    end
  end

  def translate("session/cancel", params, _state) do
    with {:ok, session_id} <- required(params, "sessionId") do
      {:dispatch, "turn.cancel", %{"command_id" => command_id(), "session_id" => session_id}}
    end
  end

  # Detaching, not ending. The session is on the other side of a socket and belongs to the
  # person rather than to the editor, so closing is this connection's business and nothing
  # happens to what is running.
  def translate("session/close", params, _state) do
    with {:ok, _session_id} <- required(params, "sessionId") do
      {:reply, %{}}
    end
  end

  def translate(method, _params, _state) do
    {:error, Error.new(:method_not_found, %{method: method})}
  end

  @doc """
  The ACP shape of what a dispatched command answered.

  Troupe's results are snake_case and say more than ACP asks for; ACP's are camelCase and
  say less. Only the translation is here — nothing is computed, because a result this
  adapter invented rather than relayed would be a second answer to a question the session
  has already answered.
  """
  @spec result_for(String.t(), map()) :: map()
  def result_for("session/new", %{"session_id" => session_id}) do
    %{"sessionId" => session_id}
  end

  # A turn ends when the agent is done, and ACP wants the reason. `input.send` answers as
  # soon as the input is accepted, so what comes back here is the acceptance — the real
  # stop reason rides on the update stream and the turn's own completion.
  def result_for("session/prompt", _accepted), do: %{"stopReason" => "end_turn"}

  def result_for(_method, _result), do: %{}

  @doc """
  What an ACP client needs subscribed after a method, so that updates start arriving.

  ACP has no `subscribe`: creating a session is expected to start the stream. Troupe
  separates the two, so the adapter closes the gap rather than the editor — which is the
  mapping in the table, *a session and its `subscribe` at `detail`*, made to happen.
  """
  @spec follow_up(String.t(), map()) :: {:subscribe, String.t()} | nil
  def follow_up("session/new", %{"session_id" => session_id}), do: {:subscribe, session_id}
  def follow_up(_method, _result), do: nil

  @doc """
  What ACP should be told about a Troupe event, or `nil` where it has no place for it.

  `nil` is the common answer and is not a gap. ACP's update set is what an editor draws;
  Troupe's event set is what a session *is*, and it includes things — seal reports, epoch
  changes, budget refusals — that an editor has no rendering for and no decision to make
  about. Sending them as some invented update type would be worse than silence, because the
  durable log is still the record and is still where they are.
  """
  @spec update_for(String.t(), Event.t()) :: map() | nil
  # The model's thinking, under ACP's own name for it, so an editor folds it rather than
  # reading it as the answer.
  def update_for(session_id, %Event{type: "llm_delta", data: %{"kind" => "reasoning", "text" => text}}) do
    notification(session_id, %{
      "sessionUpdate" => "agent_thought_chunk",
      "content" => %{"type" => "text", "text" => text}
    })
  end

  def update_for(session_id, %Event{type: "llm_delta", data: %{"text" => text}}) do
    notification(session_id, %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => text}
    })
  end

  def update_for(session_id, %Event{type: "user_input", data: %{"text" => text}}) do
    notification(session_id, %{
      "sessionUpdate" => "user_message_chunk",
      "content" => %{"type" => "text", "text" => text}
    })
  end

  def update_for(session_id, %Event{type: "tool_call_started", data: data}) do
    notification(session_id, %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => data["call_id"],
      "title" => data["name"],
      "status" => "in_progress",
      "rawInput" => data["args"] || %{}
    })
  end

  def update_for(session_id, %Event{type: "tool_call_completed", data: data}) do
    notification(session_id, %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => data["call_id"],
      "status" => if(data["ok"], do: "completed", else: "failed")
    })
  end

  def update_for(session_id, %Event{type: "todo_updated", data: %{"items" => items}}) do
    notification(session_id, %{"sessionUpdate" => "plan", "entries" => plan_entries(items)})
  end

  def update_for(_session_id, %Event{}), do: nil

  @doc """
  The permission request an approval becomes, and the four options ACP defines for it.

  `allow_always` is *allow for session* and is the reason this maps cleanly: Troupe already
  has that decision, as `approval.respond` followed by auto-approve, so ACP is naming a
  thing that exists rather than asking for one that does not.

  `reject_always` has no equivalent and is not offered. A standing refusal is not something
  Troupe can honour — every later call would have to be denied without asking, and nothing
  records that — so offering the option and then not keeping it would be the worse answer.
  """
  @spec permission_request(String.t(), map()) :: map()
  def permission_request(session_id, request) do
    %{
      "sessionId" => session_id,
      "toolCall" => %{
        "toolCallId" => request["call_id"],
        "title" => request["tool"],
        "status" => "pending",
        "rawInput" => request["args"] || %{}
      },
      "options" => [
        %{"optionId" => "allow", "name" => "Allow", "kind" => "allow_once"},
        %{
          "optionId" => "allow_session",
          "name" => "Allow for this session",
          "kind" => "allow_always"
        },
        %{"optionId" => "deny", "name" => "Reject", "kind" => "reject_once"}
      ]
    }
  end

  @doc """
  What an editor's answer to a permission request means here.

  `cancelled` is a real outcome rather than an error: ACP says a client cancelling a turn
  must answer every pending request that way, so it arrives in the ordinary course of
  somebody pressing stop.
  """
  @spec decision(map()) ::
          {:ok, :allow | :allow_session | :deny} | :cancelled | {:error, Error.t()}
  def decision(%{"outcome" => %{"outcome" => "cancelled"}}), do: :cancelled

  def decision(%{"outcome" => %{"outcome" => "selected", "optionId" => option}}) do
    case option do
      "allow" -> {:ok, :allow}
      # Not a second allow followed by a switch: `:allow_session` is a decision the approval
      # flow already has, so ACP's `allow_always` is naming something that exists rather
      # than asking for something new.
      "allow_session" -> {:ok, :allow_session}
      "deny" -> {:ok, :deny}
      other -> {:error, Error.new(:invalid_params, %{field: "optionId", value: other})}
    end
  end

  def decision(_response), do: {:error, Error.new(:invalid_params, %{field: "outcome"})}

  @doc "The stop reason a finished turn reports."
  @spec stop_reason(atom()) :: String.t()
  def stop_reason(:cancelled), do: "cancelled"
  def stop_reason(:budget), do: "max_tokens"
  def stop_reason(:refused), do: "refusal"
  def stop_reason(_done), do: "end_turn"

  # -- small readers ----------------------------------------------------------

  defp notification(session_id, update) do
    %{"sessionId" => session_id, "update" => update}
  end

  # ACP's prompt is a list of content blocks and an agent must support text and resource
  # links. Only the text is taken: a resource link is a path, and a path an ACP client
  # nominates is not a mount — the mount table decides what this session can read, and
  # quietly widening it because a block arrived would be the one shortcut that matters.
  defp prompt_text(%{"prompt" => blocks}) when is_list(blocks) do
    text =
      blocks
      |> Enum.filter(&(is_map(&1) and &1["type"] == "text" and is_binary(&1["text"])))
      |> Enum.map_join("\n", & &1["text"])

    if text == "" do
      {:error, Error.new(:invalid_params, %{field: "prompt", reason: "no text content"})}
    else
      {:ok, text}
    end
  end

  defp prompt_text(_params), do: {:error, Error.new(:invalid_params, %{field: "prompt"})}

  defp plan_entries(items) when is_list(items) do
    Enum.map(items, fn item ->
      %{
        "content" => item["text"] || item["title"] || "",
        "priority" => "medium",
        "status" => plan_status(item["status"])
      }
    end)
  end

  defp plan_entries(_items), do: []

  defp plan_status("done"), do: "completed"
  defp plan_status("in_progress"), do: "in_progress"
  defp plan_status(_pending), do: "pending"

  defp required(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new(:invalid_params, %{field: key})}
    end
  end

  # ACP says every path it sends is absolute, and this checks rather than trusts. A relative
  # `cwd` would be resolved against the daemon's working directory, which is not anywhere
  # the person meant.
  defp absolute(params, key) do
    with {:ok, path} <- required(params, key) do
      if Path.type(path) == :absolute do
        {:ok, path}
      else
        {:error, Error.new(:invalid_params, %{field: key, reason: "must be an absolute path"})}
      end
    end
  end

  # Every command Troupe takes carries one, and it is what makes a retry after a disconnect
  # a no-op. ACP has no such notion, so the adapter supplies it.
  defp command_id,
    do: "acp-" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

  @doc false
  # Kept for the connection: the methods ACP defines that this does not implement, so a
  # refusal can say so rather than looking like a typo.
  @spec unimplemented?(String.t()) :: boolean()
  def unimplemented?(method) do
    method not in @methods and
      String.starts_with?(method, ["session/", "fs/", "terminal/", "elicitation/"])
  end

  @doc false
  @spec dispatch_methods() :: %{String.t() => atom()}
  def dispatch_methods, do: Dispatch.methods()
end
