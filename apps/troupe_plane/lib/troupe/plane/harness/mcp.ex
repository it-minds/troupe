defmodule Troupe.Plane.Harness.MCP do
  @moduledoc """
  The platform as a tool surface, for the agent that is already inside it.

  `Troupe.Plane.Admin.MCP` projects the administrative surface for a person who
  administers a platform. This is the other caller, and it is much smaller: an agent in a
  session that needs a sibling to do a piece of work, or needs to look at what its team
  is running, or needs to fire a trigger somebody wrote for exactly this.

  ## Why this is not the A2A facade

  A2A is for an agent that is **not** ours — an external one, with its own card and its
  own artifacts, coming in from outside. The facade handles the one already inside
  awkwardly, because it has to mint a principal for Troupe to talk to itself and then the
  session it makes looks to the plane like a stranger's. This is four methods and no
  minting.

  ## Four tools, none destructive

  `session_create` starts a sibling, `session_get` and `sessions_list` read what the
  caller may already see through `/rpc`, and `trigger_fire` fires a trigger the caller
  may already fire. Nothing archives, erases, revokes or writes a setting: an agent that
  could delete a session is a blast radius nobody asked for, and everything here is
  something the caller could do with its own credential at `/rpc` anyway.

  That is the whole security argument, and it is deliberately boring. There is no
  privileged path: every call goes through `Troupe.Plane.Harness` with the caller's own
  context, so what an agent may do here is exactly what its credential may do there —
  which is the "no client, including ours, gets a private door" rule applied to
  ourselves one more time.

  ## The guardrail is entitlement resolution

  A sibling is created by `session.spawn`, which takes its profile and its team from the
  parent and its *ceiling* from the parent's offering: a caller may name an agent the
  parent could have run and not merely one the team may. A session cannot acquire, by
  spawning, an agent its own offering excluded.

  ## Transport

  Streamable HTTP at `/mcp/session`, one request per POST, authenticated by the same
  bearer token `/rpc` takes. A profile's bundle points an MCP server at it with the
  session principal's credential, which is how it reaches an agent — as an ordinary MCP
  server, configured the ordinary way, with nothing special about it but the address.
  """

  alias Troupe.Plane.Harness
  alias Troupe.Protocol.Error

  @protocol_version "2025-06-18"

  @instructions """
  This is the Troupe plane you are running inside. It is not an administrative interface
  and it will refuse anything destructive.

  What it is for:

  * `session_create` — start a sibling session to do a piece of work beside you. It
    inherits your profile, your team and your visibility, and it may run any agent you
    could run. Give it a prompt; it starts at once and works on its own.
  * `session_get` and `sessions_list` — what you and your team are running. Metadata
    only: status, cost, who owns it. Never the contents of a session, including your own.
  * `trigger_fire` — fire a trigger your credential may fire, with an idempotency key of
    your choosing. The same key twice is the same run.

  Spending is real. A sibling reserves budget against the same ceilings you do, and a
  refusal will name which one.
  """

  # One tool per method, and nothing that destroys. Each names the `Harness` method it is
  # and the arguments that method already validates — this table adds a schema and a
  # sentence, never a rule, because a rule here would be a second opinion about what is
  # allowed and the two would drift.
  @tools [
    %{
      name: "session_create",
      method: "session.spawn",
      summary:
        "Start a sibling session beside this one: same profile, same team, same visibility, and any agent this session could run.",
      required: ["parent", "prompt"],
      properties: %{
        "parent" => %{
          "type" => "string",
          "description" => "Your own session id. The sibling takes its profile and ceiling from it."
        },
        "prompt" => %{"type" => "string", "description" => "What the sibling is asked to do."},
        "agent" => %{
          "type" => "string",
          "description" => "An agent this session could run. Absent uses the profile's default."
        },
        "title" => %{"type" => "string", "description" => "A short name for a listing."},
        "terms" => %{
          "type" => "object",
          "description" =>
            "Caps for the sibling: budget_micros, max_turns, wall_clock_seconds, approvals."
        }
      }
    },
    %{
      name: "session_get",
      method: "session.get",
      summary: "One session you may see: status, owner, cost and what started it. Never its contents.",
      required: ["session_id"],
      properties: %{"session_id" => %{"type" => "string"}}
    },
    %{
      name: "sessions_list",
      method: "sessions.list",
      summary:
        "The sessions you may see. `source` narrows to how they were started — `any` for everything nobody typed.",
      required: [],
      properties: %{
        "profile" => %{"type" => "string"},
        "status" => %{"type" => "string"},
        "source" => %{"type" => "string"},
        "trigger" => %{"type" => "string"},
        "limit" => %{"type" => "integer"}
      }
    },
    %{
      name: "trigger_fire",
      method: "trigger.fire",
      summary: "Fire a trigger your credential may fire. The same idempotency key twice is one run.",
      required: ["trigger", "idempotency_key"],
      properties: %{
        "trigger" => %{"type" => "string", "description" => "By name, by team/name, or by id."},
        "idempotency_key" => %{"type" => "string"},
        "event" => %{"type" => "object", "description" => "A small map the prompt template reads."}
      }
    }
  ]

  @by_name Map.new(@tools, &{&1.name, &1})

  @doc "Answer one MCP request for one caller."
  @spec handle(map(), Harness.context()) :: {:reply, map()} | :noreply
  def handle(request, context)

  def handle(%{"method" => method, "id" => id} = request, context) do
    {:reply, answer(method, Map.get(request, "params") || %{}, id, context)}
  end

  # A request without an id is a notification, whatever it is called. Nothing goes back.
  def handle(%{"method" => _method}, _context), do: :noreply

  def handle(_malformed, _context), do: {:reply, error(nil, -32_600, "not a JSON-RPC request")}

  @doc "Every tool this server offers."
  @spec tools() :: [map()]
  def tools do
    Enum.map(@tools, fn tool ->
      %{
        "name" => tool.name,
        "description" => tool.summary,
        "inputSchema" => %{
          "type" => "object",
          "properties" => tool.properties,
          "required" => tool.required
        }
      }
    end)
  end

  defp answer("initialize", _params, id, _context) do
    result(id, %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => %{"name" => "troupe-session", "version" => version()},
      "instructions" => @instructions
    })
  end

  defp answer("ping", _params, id, _context), do: result(id, %{})
  defp answer("tools/list", _params, id, _context), do: result(id, %{"tools" => tools()})

  # Neither is offered in `initialize`, so a well-behaved client does not ask. Answered
  # anyway, because several ask regardless and an error in a log is a support question
  # about something that is working.
  defp answer("resources/list", _params, id, _context), do: result(id, %{"resources" => []})
  defp answer("prompts/list", _params, id, _context), do: result(id, %{"prompts" => []})

  defp answer("tools/call", params, id, context) do
    case Map.fetch(@by_name, params["name"]) do
      :error -> error(id, -32_602, "no tool named #{inspect(params["name"])}")
      {:ok, tool} -> result(id, invoke(tool, params["arguments"] || %{}, context))
    end
  end

  defp answer(method, _params, id, _context) do
    error(id, -32_601, "this server does not implement #{method}")
  end

  defp invoke(tool, arguments, context) do
    case Harness.call(tool.method, arguments, context) do
      {:ok, answer} -> content(answer)
      {:error, %Error{} = failure} -> refusal(describe(failure))
    end
  end

  defp content(answer) do
    %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(answer, pretty: true)}],
      "structuredContent" => structured(answer)
    }
  end

  defp structured(answer) when is_map(answer), do: answer
  defp structured(answer), do: %{"result" => answer}

  # An error the *model* sees, not one the transport swallows. A refused call is
  # information — a budget ceiling, an agent this session may not run — and the caller
  # should be able to read it and try something else.
  defp refusal(message) do
    %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}
  end

  defp describe(%Error{message: message, data: data}) when data not in [nil, %{}] do
    "#{message} (#{Jason.encode!(data)})"
  end

  defp describe(%Error{message: message}), do: message

  defp result(id, payload), do: %{"jsonrpc" => "2.0", "id" => id, "result" => payload}

  defp error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp version, do: Application.spec(:troupe_plane, :vsn) |> to_string()
end
