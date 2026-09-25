defmodule Troupe.Protocol.Schema do
  @moduledoc """
  What is in each event's `data` and each command's params, as data.

  This is the definition the JSON Schema in `protocol/schema/v1/` is generated from, so
  the published schema cannot drift from what the server means. It is also what
  `mix troupe.schema.diff` compares against the committed copy, which is what stops a
  field being quietly removed or retyped between releases.

  Within major version 1 the rules are: fields may be added; fields may not be removed,
  renamed, retyped, or newly made required; event types and enum values may be added.
  A rename is a removal and an addition, and it is the removal that breaks clients.
  """

  @type shape :: %{String.t() => %{type: type(), required: boolean()}}
  @type type ::
          :string
          | :integer
          | :number
          | :boolean
          | :object
          | :array
          | :text_or_blob
          | {:array, type()}

  defp required(type), do: %{type: type, required: true}
  defp optional(type), do: %{type: type, required: false}

  # -- durable events ---------------------------------------------------------

  @doc "Every durable event type and the shape of its `data`."
  @spec events() :: %{String.t() => shape()}
  def events do
    %{
      # `kind` is `team` for a session on a pod and `local` for one on a laptop;
      # `origin` says what started it — a person, a trigger, a run — when it was not a
      # person typing.
      "session_created" => %{
        "workspace" => required(:string),
        "profile" => required(:string),
        "visibility" => required(:string),
        "bundle_version" => optional(:string),
        "kind" => optional(:string),
        # Who it belongs to, where anybody was told; and what it was allowed to see —
        # the agent, skill and MCP server names the grant resolved to, or absent for no
        # restriction, which is what a local session and an unnarrowed grant both mean.
        "owner" => optional(:string),
        "entitlements" => optional(:object),
        "origin" => optional(:object),
        # The session this one was made as a branch of, when a client said so.
        "parent" => optional(:string)
      },
      # The child's first event, and the only place the lineage is written down in the log.
      # `parent` carries the id, the seq forked at and the parent's head hash there, so a
      # reader holding only the child can say what it came from and a verifier can say the
      # claim is about a real point in a real chain.
      #
      # The parent gets nothing. It is not amended, not notified, and a fork of a dormant
      # session does not wake it — which is what makes forking cost the person who forks
      # and nobody else.
      "session_forked" => %{
        "parent" => required(:object),
        "reason" => required(:string)
      },
      "agent_started" => %{
        "profile" => required(:string),
        "mode" => required(:string),
        "bundle_version" => optional(:string)
      },
      "agent_restarted" => %{
        "replayed_events" => required(:integer),
        "interrupted" => optional(:boolean),
        "incomplete_calls" => optional({:array, :string})
      },
      "user_input" => %{"source" => required(:string), "text" => required(:string)},
      "input_queued" => %{
        "command_id" => required(:string),
        "author" => required(:string),
        "text" => required(:string)
      },
      "input_accepted" => %{
        "command_id" => required(:string),
        "author" => required(:string)
      },
      "llm_request" => %{
        "model" => required(:string),
        "message_count" => required(:integer),
        "tools" => required({:array, :string}),
        "profile" => required(:string)
      },
      "llm_response" => %{
        "message" => required(:object),
        "usage" => optional(:object),
        "stop_reason" => optional(:string),
        "model" => optional(:string),
        # What the gateway in front of the provider said about the call it billed:
        # `request_id` and `cost_micros`. Optional because an event written before there
        # was a gateway to ask carries neither, and because a gateway may answer with
        # one and not the other.
        "gateway" => optional(:object)
      },
      # `reason` is a sentence a person can act on (Decision 659), not a term.
      "llm_error" => %{"reason" => required(:string)},
      # A reply the output cap cut (`max_tokens`) or that said nothing (`empty`): `note`
      # when the model was asked again, `calls` when tool calls cut mid-argument were
      # answered with an error, `final` when it had been asked once already and the agent
      # ends under `output_truncated` or `empty_reply` (Decision 659).
      "truncated" => %{
        "reason" => required(:string),
        "note" => optional(:string),
        "calls" => optional(:integer),
        "final" => optional(:boolean)
      },
      "tool_call_started" => %{
        "call_id" => required(:string),
        "name" => required(:string),
        "args" => required(:object),
        # Which credential an MCP call goes out as: `"profile"` or `"person:<subject>"`.
        # Absent for every other tool, because a built-in runs as the pod and a
        # client-hosted tool runs on somebody's laptop, and neither is a choice anybody
        # made.
        "identity" => optional(:string),
        # The same question with its other half: whose credential *and* whose session.
        # A field is never retyped within a major version, so the pair arrives beside
        # `identity` rather than in place of it — and `identity` keeps meaning exactly
        # what it meant to every reader written before there were two halves.
        "principal" => optional(:object)
      },
      "tool_call_completed" => %{
        "call_id" => required(:string),
        "name" => required(:string),
        "ok" => required(:boolean),
        # Text, or `{"blob", "size", "preview", "truncated"}` when it was too large to
        # put on the wire.
        "content" => required(:text_or_blob)
      },
      "tool_results" => %{"results" => required(:array)},
      "todo_updated" => %{"items" => required(:array), "source" => optional(:string)},
      "profile_switched" => %{"from" => optional(:string), "to" => required(:string)},
      "delegation_started" => %{
        "call_id" => required(:string),
        "agent" => required(:string),
        "child_path" => required({:array, :string}),
        "task" => required(:string)
      },
      "compacted" => %{
        "summary" => required(:string),
        # `threshold`, or `context_overflow` when the provider refused the prompt and
        # compacting is how the turn was sent again (Decision 659).
        "reason" => optional(:string),
        "conversation" => optional(:array)
      },
      "budget_exhausted" => %{"limit" => required(:string)},
      # The budget is spent and the agent asks before the next model call (Decision 660).
      # The question itself is a `question_asked` under the same `call_id`.
      "budget_ask_started" => %{
        "call_id" => required(:string),
        "dimension" => required(:string),
        "used" => required(:integer),
        "limit" => required(:integer),
        "detail" => required(:string)
      },
      # `allow` (one more slice, `grant` says how much), `always` (this agent and its
      # subagents stop asking) or `deny` (`budget_exhausted` follows).
      "budget_ask_answered" => %{
        "call_id" => required(:string),
        "decision" => required(:string),
        "grant" => optional(:object)
      },
      # A limit is near (Decision 655): once per dimension per agent.
      "budget_warning" => %{
        "dimension" => required(:string),
        "used" => required(:integer),
        "limit" => required(:integer),
        "fraction" => required(:number),
        "detail" => required(:string)
      },
      "agent_done" => %{
        "reason" => required(:string),
        "summary" => optional(:string),
        "limit" => optional(:string)
      },
      # Input that arrived after an agent finished. Recorded rather than dropped: it is
      # the difference between "the user said nothing" and "the user said something and
      # nobody was listening".
      "input_after_done" => %{"source" => required(:string)},
      "cancelled" => %{},
      "approval_requested" => %{
        "call_id" => required(:string),
        "tool" => required(:string),
        "args" => required(:object),
        "agent_path" => required({:array, :string})
      },
      "approval_decided" => %{
        "call_id" => required(:string),
        "tool" => required(:string),
        "args" => required(:object),
        "agent_path" => required({:array, :string}),
        "decision" => required(:string)
      },
      # `ask_user` (Decision 651): the agent hands a decision to a person and waits.
      "question_asked" => %{
        "call_id" => required(:string),
        "agent_path" => required({:array, :string}),
        "question" => required(:string),
        "options" => required(:array),
        "multiple" => required(:boolean)
      },
      "question_answered" => %{
        "call_id" => required(:string),
        "text" => required(:string)
      },
      "approval_resolved" => %{
        "call_id" => required(:string),
        "resolved_by" => required(:string)
      },
      # What the session may touch: `[{name, kind, root, mode}]`. Resolved once, at
      # creation, and recorded so that a replay can tell what was allowed at the time.
      "mounts_resolved" => %{"mounts" => required(:array)},
      # Something other than a person started this session, and this is the whole of what
      # that was: which of the seven sources, under which trigger document, on whose
      # authority, against which idempotency key, carrying what.
      #
      # `payload_digest` is a hash and never a payload — a webhook body is content, and
      # content does not belong in an event that outlives the session that received it.
      # It and `revision` are optional because a session started before either existed
      # has neither, and a value invented here would read as one that was measured.
      "trigger_fired" => %{
        "source" => required(:string),
        "idempotency_key" => required(:string),
        "principal" => required(:object),
        "revision" => optional(:string),
        "payload_digest" => optional(:string)
      },
      "published" => %{
        "source" => required(:string),
        "destination" => required(:string),
        "hash" => required(:string),
        "bytes" => required(:integer),
        "direction" => required(:string)
      },
      "session_dormant" => %{"last_seq" => required(:integer)},
      "session_activated" => %{"epoch" => required(:string), "pod" => optional(:string)},
      "session_resumed" => %{
        "dormant_ms" => required(:integer),
        "moved" => required(:boolean)
      },
      # The session's configuration changed under it, which happens only at activation and
      # only when the version it was pinned to has been retired. Durable, because the
      # model is entitled to know its tools may have changed.
      "config_upgraded" => %{
        "channel" => required(:string),
        "from" => optional(:integer),
        "to" => required(:integer),
        "hash" => required(:string),
        # Re-resolved at this activation: a publish can add an entry the team is not
        # entitled to, so the event that says the configuration moved says what the
        # session may now see.
        "entitlements" => optional(:object)
      },
      "session_read_only" => %{"reason" => required(:string)},
      "session_archived" => %{},
      "session_erased" => %{},
      "fs_changed" => %{
        "path" => required(:string),
        "hash" => required(:string),
        "size" => required(:integer)
      },
      # A capability somebody minted over this session: a link that carries a role rather
      # than a name. Durable, because a share is a decision about who may read what was
      # said, and a decision of that kind that left no trace would be one nobody could
      # audit after the fact.
      #
      # `id` is the share's public identifier and never the secret — the secret is shown to
      # whoever minted it, once, and the plane keeps a salted digest. An event carrying it
      # would put a working credential in a log that outlives the session.
      #
      # `role` is `observe` or `control`. Never `admin`: a capability that could administer
      # a session could grant further capabilities, and a link that can mint links is a link
      # nobody can reason about.
      "share_created" => %{
        "id" => required(:string),
        "role" => required(:string),
        "expires_at" => required(:string),
        "audience" => optional(:string)
      },
      "share_revoked" => %{"id" => required(:string), "reason" => optional(:string)},
      "acl_granted" => %{"subject" => required(:string), "role" => required(:string)},
      "acl_revoked" => %{"subject" => required(:string), "role" => required(:string)},
      # Client-hosted tools. Durable, all three, because a tool that ran on somebody's
      # laptop is part of what happened in this session and a replay that did not say so
      # would be a transcript with a hole in it.
      "tools_registered" => %{
        "tools" => required({:array, :string}),
        "connection" => required(:string),
        "consent" => required(:object)
      },
      "tools_unregistered" => %{
        "tools" => required({:array, :string}),
        "connection" => required(:string),
        "reason" => required(:string)
      },
      "session_tainted" => %{
        "kind" => required(:string),
        "tools" => required({:array, :string}),
        "actor" => required(:string)
      }
    }
  end

  @doc "Ephemeral event types. Droppable, never persisted, and never part of a replay."
  @spec ephemeral_events() :: %{String.t() => shape()}
  def ephemeral_events do
    %{
      "llm_delta" => %{
        "kind" => required(:string),
        "text" => optional(:string),
        "id" => optional(:string),
        "name" => optional(:string),
        "fragment" => optional(:string)
      },
      "agent_state" => %{
        "state" => required(:string),
        "profile" => required(:string),
        "agent" => required({:array, :string}),
        "todos" => required(:array),
        "budget" => required(:object),
        "done_reason" => optional(:string)
      },
      "progress" => %{"message" => required(:string)},
      # Never durable, and not by a filter: presence is published through a function that
      # has no path to the log at all. `state` is `joined`, `left`, `focused` or `typing`.
      "presence" => %{
        "subject" => required(:string),
        "state" => required(:string),
        "display_name" => optional(:string),
        "agent" => optional({:array, :string})
      },
      "summary_diff" => %{"changed" => required(:object)},
      "watch_notice" => %{"message" => required(:string)}
    }
  end

  # -- commands ---------------------------------------------------------------

  @doc "Every command method and the shape of its params."
  @spec commands() :: %{String.t() => shape()}
  def commands do
    %{
      "initialize" => %{
        "protocol_version" => required(:string),
        "client_info" => required(:object),
        "capabilities" => optional(:object),
        "auth" => optional(:object)
      },
      "subscribe" => %{
        "command_id" => required(:string),
        "topic" => required(:string),
        "level" => optional(:string),
        "from_seq" => optional(:integer)
      },
      "unsubscribe" => %{"subscription_id" => required(:string)},
      "session.list" => %{"filter" => optional(:object)},
      "session.get" => %{"session_id" => required(:string)},
      "session.create" => %{
        "command_id" => required(:string),
        "workspace" => required(:string),
        "profile" => optional(:string),
        "prompt" => optional(:string),
        "worktree" => optional(:string),
        "config" => optional(:object),
        "parent" => optional(:string),
        "workflow" => optional(:string)
      },
      "session.archive" => %{
        "command_id" => required(:string),
        "session_id" => required(:string)
      },
      "question.answer" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "call_id" => required(:string),
        "text" => required(:string)
      },
      "session.pin" => %{"command_id" => required(:string), "session_id" => required(:string)},
      "session.unpin" => %{"command_id" => required(:string), "session_id" => required(:string)},
      "session.erase" => %{"command_id" => required(:string), "session_id" => required(:string)},
      "input.send" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "text" => required(:string)
      },
      "turn.cancel" => %{
        "command_id" => required(:string),
        "session_id" => required(:string)
      },
      "profile.switch" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "profile" => required(:string)
      },
      "approval.respond" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "call_id" => required(:string),
        "decision" => required(:string)
      },
      "todo.edit" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "action" => required(:string),
        "id" => optional(:string),
        "content" => optional(:string)
      },
      # Files, resolved through the session's mount table and scope-checked like every
      # other command. Reading is `observe`; putting a file into a workspace is steering
      # the session and needs `control`.
      "fs.list" => %{
        "session_id" => required(:string),
        "path" => optional(:string)
      },
      "fs.read" => %{
        "session_id" => required(:string),
        "path" => required(:string)
      },
      "fs.upload" => %{
        "session_id" => required(:string),
        "path" => required(:string),
        "content" => required(:string),
        "command_id" => optional(:string)
      },
      "blob.get" => %{
        "session_id" => required(:string),
        "blob" => required(:string),
        "range" => optional(:array)
      },
      "fleet.get" => %{},
      "workspace.recent" => %{"limit" => optional(:integer)},
      "workspace.search" => %{"query" => required(:string), "limit" => optional(:integer)},
      "workflows.list" => %{"workspace" => required(:string)},
      "memory.get" => %{"workspace" => required(:string)},
      "mcp.status" => %{"session_id" => required(:string)},
      "memory.forget" => %{"command_id" => required(:string), "workspace" => required(:string)},
      "worktree.list" => %{"workspace" => optional(:string)},
      "worktree.remove" => %{
        "command_id" => required(:string),
        "path" => required(:string),
        "force" => optional(:boolean)
      },
      "worktree.merge" => %{
        "command_id" => required(:string),
        "workspace" => required(:string),
        "path" => required(:string),
        "message" => optional(:string)
      },
      "worktree.discard" => %{
        "command_id" => required(:string),
        "workspace" => required(:string),
        "path" => required(:string)
      },
      "watch.set" => %{
        "command_id" => required(:string),
        "workspace" => required(:string),
        "enabled" => optional(:boolean)
      },
      # Presence. No `command_id`: it is not an effect to be replayed, and a client that
      # retried one would be asserting something it no longer knows to be true.
      "presence.set" => %{
        "session_id" => required(:string),
        "state" => required(:string),
        "agent" => optional({:array, :string})
      },
      "tools.register" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "tools" => required(:array),
        "consent" => optional(:object)
      },
      "tools.unregister" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "tools" => optional({:array, :string})
      },
      # The machine's model settings — the daemon's only; a worker answers
      # `method_not_found`. The key goes in through `config.models` and `config.set` and
      # never comes back out: `config.get` reports `api_key_set`.
      "config.get" => %{"workspace" => optional(:string)},
      "config.models" => %{
        "provider" => optional(:string),
        "base_url" => optional({:nullable, :string}),
        "api_key" => optional(:string),
        "auth" => optional(:string)
      },
      "config.set" => %{
        "command_id" => required(:string),
        "provider" => required(:string),
        "base_url" => optional({:nullable, :string}),
        "auth" => optional(:string),
        "api_key" => optional(:string),
        "models" => optional(:object),
        "workspace" => optional(:string)
      },
      "config.import" => %{
        "command_id" => required(:string),
        "from" => required(:string),
        "workspace" => optional(:string)
      }
    }
  end

  @doc """
  Requests the **server** sends the client, and the shape of their params.

  One so far. It exists because a client-hosted tool runs where the client is, so the
  agent's call has to travel outwards over a connection the client already holds — there
  is nothing to dial back to, and a laptop behind a NAT could not be dialled anyway.
  """
  @spec server_requests() :: %{String.t() => shape()}
  def server_requests do
    %{
      "tool.invoke" => %{
        "call_id" => required(:string),
        "name" => required(:string),
        "arguments" => required(:object)
      }
    }
  end

  # -- JSON Schema ------------------------------------------------------------

  @doc "Every document that belongs in `protocol/schema/v1/`, keyed by its relative path."
  @spec documents() :: %{Path.t() => map()}
  def documents do
    durable =
      for {type, shape} <- events(),
          into: %{},
          do: {"events/#{type}.json", document("events", type, shape)}

    ephemeral =
      for {type, shape} <- ephemeral_events(),
          into: %{},
          do: {"events/#{type}.json", document("events", type, shape)}

    commands =
      for {method, shape} <- commands(),
          into: %{},
          do: {"commands/#{method}.json", document("commands", method, shape)}

    # Under `commands/` too, and deliberately: a client that has to *answer* one needs
    # its shape published exactly as much as one it sends, and a second directory would
    # only make it easier to publish one and forget the other.
    server =
      for {method, shape} <- server_requests(),
          into: %{},
          do: {"commands/#{method}.json", document("commands", method, shape)}

    durable
    |> Map.merge(ephemeral)
    |> Map.merge(commands)
    |> Map.merge(server)
  end

  defp document(kind, name, shape) do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "https://troupe.dev/schema/v1/#{kind}/#{name}.json",
      "title" => name,
      "type" => "object",
      "properties" => Map.new(shape, fn {field, spec} -> {field, json_type(spec.type)} end),
      "required" =>
        shape |> Enum.filter(&elem(&1, 1).required) |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
      # Fields may be added within a major version, so a document with more than this
      # is valid — that is the compatibility rule, written into the schema itself.
      "additionalProperties" => true
    }
  end

  defp json_type({:array, inner}), do: %{"type" => "array", "items" => json_type(inner)}
  defp json_type(:text_or_blob), do: %{"type" => ["string", "object"]}
  defp json_type({:nullable, inner}), do: %{"type" => [Atom.to_string(inner), "null"]}
  defp json_type(:object), do: %{"type" => "object"}
  defp json_type(type), do: %{"type" => Atom.to_string(type)}

  # -- compatibility ----------------------------------------------------------

  @type incompatibility ::
          {:removed_document, Path.t()}
          | {:removed_field, Path.t(), String.t()}
          | {:retyped_field, Path.t(), String.t(), map(), map()}
          | {:newly_required, Path.t(), String.t()}

  @doc """
  Every breaking change from a committed set of documents to a current one.

  Empty means the change is compatible. A new document or a new optional field is not
  listed, because adding either is exactly what clients are built to tolerate.
  """
  @spec incompatibilities(%{Path.t() => map()}, %{Path.t() => map()}) :: [incompatibility()]
  def incompatibilities(committed, current) do
    Enum.flat_map(committed, fn {path, old} ->
      case Map.fetch(current, path) do
        :error -> [{:removed_document, path}]
        {:ok, new} -> document_incompatibilities(path, old, new)
      end
    end)
  end

  defp document_incompatibilities(path, old, new) do
    old_properties = Map.get(old, "properties", %{})
    new_properties = Map.get(new, "properties", %{})
    old_required = MapSet.new(Map.get(old, "required", []))
    new_required = MapSet.new(Map.get(new, "required", []))

    removed_or_retyped =
      Enum.flat_map(old_properties, fn {field, old_type} ->
        case Map.fetch(new_properties, field) do
          :error -> [{:removed_field, path, field}]
          {:ok, ^old_type} -> []
          {:ok, new_type} -> [{:retyped_field, path, field, old_type, new_type}]
        end
      end)

    newly_required =
      new_required
      |> MapSet.difference(old_required)
      |> Enum.map(&{:newly_required, path, &1})

    Enum.sort(removed_or_retyped ++ newly_required)
  end

  @doc "One breaking change, in a sentence a person can act on."
  @spec describe(incompatibility()) :: String.t()
  def describe({:removed_document, path}), do: "#{path}: removed; clients still expect it"

  def describe({:removed_field, path, field}),
    do: "#{path}: field #{field} was removed or renamed"

  def describe({:retyped_field, path, field, old, new}) do
    "#{path}: field #{field} changed type from #{inspect(old)} to #{inspect(new)}"
  end

  def describe({:newly_required, path, field}) do
    "#{path}: field #{field} is now required; older clients do not send it"
  end

  # -- validation -------------------------------------------------------------

  @doc """
  Check one event's `data` against its shape.

  Unknown event types pass: a client — or a test — reading a log written by a newer
  version must tolerate what it has never heard of, and so must this.
  """
  @spec validate_event(String.t(), map()) :: :ok | {:error, [String.t()]}
  def validate_event(type, data) do
    case Map.get(events(), type) || Map.get(ephemeral_events(), type) do
      nil -> :ok
      shape -> validate(shape, data)
    end
  end

  @doc "Check a map against a shape."
  @spec validate(shape(), map()) :: :ok | {:error, [String.t()]}
  def validate(shape, data) do
    problems =
      Enum.flat_map(shape, fn {field, spec} ->
        case {Map.fetch(data, field), spec.required} do
          {:error, true} -> ["missing required field #{field}"]
          {:error, false} -> []
          {{:ok, nil}, _} -> []
          {{:ok, value}, _} -> type_problem(field, spec.type, value)
        end
      end)

    if problems == [], do: :ok, else: {:error, problems}
  end

  defp type_problem(field, type, value) do
    if matches?(type, value), do: [], else: ["#{field} should be #{inspect(type)}"]
  end

  defp matches?(:string, value), do: is_binary(value)
  defp matches?(:integer, value), do: is_integer(value)
  defp matches?(:number, value), do: is_number(value)
  defp matches?(:boolean, value), do: is_boolean(value)
  defp matches?(:object, value), do: is_map(value)
  defp matches?(:array, value), do: is_list(value)
  defp matches?(:text_or_blob, value), do: is_binary(value) or is_map(value)

  defp matches?({:array, inner}, value) do
    is_list(value) and Enum.all?(value, &matches?(inner, &1))
  end
end
