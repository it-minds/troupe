defmodule Troupe.Plane.Admin.MCP do
  @moduledoc """
  The admin surface as an MCP server: the fourth rendering of `Troupe.Plane.Admin`.

  Troupe already speaks MCP as a *client* — a session reaches a team's servers through
  `Troupe.MCP.Client`. This is the other direction, and it exists because the person
  administering a platform of agents increasingly is one: "which profile is over budget
  and what changed last night" is three list calls and a join, which is a chore for a
  human with a browser and nothing at all for a model with tools.

  Every tool here is one admin method, generated from `Troupe.Plane.Admin.API`'s table.
  Nothing is written twice: a method added to that table appears here with its summary and
  its schema, and `Troupe.Plane.AdminParityTest` fails if it arrives without them. There is
  no privileged path — this goes through the same context, with the same actor, as the
  panel and the JSON-RPC methods.

  ## What is deliberately not here

  **No filtering of the tool list by role.** A team admin sees `admin_profile_put` and is
  refused if they call it, rather than not seeing it. Hiding it would mean this module
  holding a second opinion about who may do what, and the two opinions would diverge — the
  context is the authority on authorisation and a refusal from it names the role required,
  which is more use to a caller than an absence they cannot ask about.

  **No session content, because there is none to have.** No admin method returns the
  contents of a session and none can be added without failing the parity test, so there is
  no MCP tool that could leak one. That is worth stating in the server's own instructions,
  which is why `initialize` says it: a model that believes it can read a transcript will
  spend a turn looking for the tool.

  **Confirmation is not optional.** A destructive method's tool takes a `confirm` argument
  that must repeat the identifier exactly. The design makes typed confirmation the model
  for everything irreversible, on the grounds that the friction should be *understanding*
  rather than ceremony; a caller with no dialog to read gets the same rule as the only
  guard it has. It is checked here rather than in the context because the context is also
  what the panel's already-confirmed dialog calls.

  ## Transport

  Streamable HTTP, one request per POST, at `/mcp` on the plane — mounted beside `/rpc`
  and authenticated by exactly the same bearer token, because it is exactly the same kind
  of caller. Stateless: no session id is issued and none is required, which is allowed and
  means a plane replica can answer any request without the replicas sharing anything.
  """

  alias Troupe.Plane.Admin
  alias Troupe.Plane.Admin.API
  alias Troupe.Plane.Admin.API.{Argument, Method}
  alias Troupe.Protocol.Error

  # The revision of MCP this speaks. Named rather than echoed back from the client's
  # `initialize`, so a client asking for something newer is told what it actually gets.
  @protocol_version "2025-06-18"

  @instructions """
  This is the administrative interface of a Troupe plane: a platform that runs coding
  agents for teams. You are not talking to an agent — you are administering the machines,
  budgets, teams and configuration that agents run inside.

  How to work here:

  * Read before you write. `admin_overview` first; then the list tool for whatever you are
    about to change. A profile write replaces the spec, so read the profile with
    `admin_profile_get` and send it back changed rather than composing one from nothing.
  * Administrators cannot read session content. No tool returns it, and this is a property
    of the platform rather than a permission you lack. `admin_sessions_list` gives you who,
    where, what state and what it cost.
  * Tools marked destructive take a `confirm` argument that must repeat the identifier
    exactly. That is the only guard on them.
  * On a GitOps plane, writing a profile commits it for review and changes nothing in the
    cluster. Check `admin_provisioning_mode` if it matters; the answer to a write says
    which happened.
  * What you may do depends on who the token belongs to. A refusal names the role it
    wanted; it is not a bug to be worked around.
  """

  @doc """
  Answer one MCP request.

  `{:reply, message}` for a request, `:noreply` for a notification — which is the whole of
  the distinction JSON-RPC makes and the only thing the transport needs to know.
  """
  @spec handle(map(), Admin.actor()) :: {:reply, map()} | :noreply
  def handle(%{"method" => "notifications/" <> _rest}, _actor), do: :noreply

  def handle(%{"method" => method, "id" => id} = request, actor) do
    {:reply, answer(method, Map.get(request, "params") || %{}, id, actor)}
  end

  # A request without an id is a notification by JSON-RPC's definition, whatever it is
  # called. Nothing is sent back, including for a method that does not exist.
  def handle(%{"method" => _method}, _actor), do: :noreply

  def handle(_malformed, _actor) do
    {:reply, error(nil, -32_600, "not a JSON-RPC request")}
  end

  defp answer("initialize", _params, id, _actor) do
    result(id, %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => %{"name" => "troupe-admin", "version" => version()},
      "instructions" => @instructions
    })
  end

  defp answer("ping", _params, id, _actor), do: result(id, %{})

  defp answer("tools/list", _params, id, _actor), do: result(id, %{"tools" => tools()})

  # Neither is offered in `initialize`, so a well-behaved client does not ask. Answered
  # with an empty list anyway, because several clients ask regardless and an error in a
  # log is a support question about something that is working.
  defp answer("resources/list", _params, id, _actor), do: result(id, %{"resources" => []})
  defp answer("prompts/list", _params, id, _actor), do: result(id, %{"prompts" => []})

  defp answer("tools/call", params, id, actor) do
    name = params["name"]
    arguments = params["arguments"] || %{}

    case API.method(method_for(name)) do
      nil ->
        error(id, -32_602, "no tool named #{inspect(name)}")

      %Method{} = method ->
        result(id, invoke(method, arguments, actor))
    end
  end

  defp answer(method, _params, id, _actor) do
    error(id, -32_601, "this server does not implement #{method}")
  end

  # -- calling a tool ---------------------------------------------------------

  defp invoke(%Method{} = method, arguments, actor) do
    case confirmed(method, arguments) do
      :ok ->
        case API.call(method.name, arguments, actor) do
          {:ok, answer} -> content(answer)
          {:error, %Error{} = failure} -> refusal(describe(failure))
        end

      {:error, message} ->
        refusal(message)
    end
  end

  defp confirmed(%Method{confirm: nil}, _arguments), do: :ok

  defp confirmed(%Method{confirm: field} = method, arguments) do
    expected = arguments[field]
    given = arguments["confirm"]

    cond do
      is_nil(expected) ->
        {:error, "#{method.name} needs #{field}"}

      given == expected ->
        :ok

      true ->
        {:error,
         "#{method.name} is irreversible: pass confirm with the same value as #{field} " <>
           "(#{inspect(expected)}) to say you mean this one"}
    end
  end

  # A result the model can read and a result a program can use. The text is the whole
  # answer rather than a summary of it: a tool that paraphrases its own output makes the
  # model reason about the paraphrase.
  defp content(answer) do
    %{"content" => [text(answer)], "structuredContent" => structured(answer)}
  end

  defp structured(answer) when is_map(answer), do: answer
  # MCP's structured content is an object. A list is wrapped rather than dropped, so a
  # client that reads only the structured half still gets the rows.
  defp structured(answer), do: %{"result" => answer}

  defp text(answer) do
    %{"type" => "text", "text" => Jason.encode!(answer, pretty: true)}
  end

  # An error the *model* sees, not a JSON-RPC error the transport swallows: a refused call
  # is information for the caller — the wrong role, a name that does not exist — and it
  # should be able to read it and try something else.
  defp refusal(message) do
    %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}
  end

  defp describe(%Error{message: message, data: data}) when data not in [nil, %{}] do
    "#{message} (#{Jason.encode!(data)})"
  end

  defp describe(%Error{message: message}), do: message

  # -- the tools --------------------------------------------------------------

  @doc "Every tool this server offers, which is every admin method."
  @spec tools() :: [map()]
  def tools, do: Enum.map(API.list(), &tool/1)

  @doc """
  The tool name for a method: dots become underscores.

  MCP names are restricted to what an identifier may contain, so `admin.profile.put`
  cannot be a tool name as it stands. The mapping is mechanical and reversible on purpose
  — an operator reading a transcript of what a model did should be able to find the same
  call in the audit log, where it is written the other way.
  """
  @spec tool_name(String.t()) :: String.t()
  def tool_name(method), do: String.replace(method, ".", "_")

  @doc "The method a tool name refers to, or `nil`."
  @spec method_for(term()) :: String.t() | nil
  def method_for(name) when is_binary(name), do: String.replace(name, "_", ".")
  def method_for(_other), do: nil

  defp tool(%Method{} = method) do
    %{
      "name" => tool_name(method.name),
      # The method's own name, so the same string appears in the tool list, the audit log
      # and every client that calls the method.
      "title" => method.name,
      "description" => description(method),
      "inputSchema" => input_schema(method),
      "annotations" => annotations(method)
    }
  end

  # The summary, plus the one thing a model cannot infer from it.
  defp description(%Method{risk: :destructive, confirm: field} = method) do
    method.summary <>
      "\n\nThis is irreversible. Pass confirm with the same value as #{field}."
  end

  defp description(%Method{} = method), do: method.summary

  defp annotations(%Method{} = method) do
    %{
      "title" => method.name,
      "readOnlyHint" => method.risk == :read,
      "destructiveHint" => method.risk == :destructive,
      # A write that names the whole state — a profile, a trigger, a team's fields — lands
      # in the same place twice. A read does too. The ones that do not are the ones that
      # mint something or fire something.
      "idempotentHint" => method.risk != :write or idempotent?(method),
      # Everything here is this plane and nothing else.
      "openWorldHint" => false
    }
  end

  @not_idempotent ~w(admin.principal.create admin.trigger.run admin.bundle.publish)

  defp idempotent?(%Method{name: name}), do: name not in @not_idempotent

  defp input_schema(%Method{} = method) do
    properties =
      method.arguments
      |> Map.new(&{&1.name, property(&1)})
      |> put_confirm(method)

    required =
      method.arguments
      |> Enum.filter(& &1.required)
      |> Enum.map(& &1.name)
      |> then(fn names -> if method.confirm, do: names ++ ["confirm"], else: names end)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      # A misspelled field is the failure this catches: without it, `budget` instead of
      # `budget_micros` is accepted, changes nothing, and reports success.
      "additionalProperties" => false
    }
  end

  defp put_confirm(properties, %Method{confirm: nil}), do: properties

  defp put_confirm(properties, %Method{confirm: field}) do
    Map.put(properties, "confirm", %{
      "type" => "string",
      "description" => "Repeat #{field} exactly. The call is refused if it does not match."
    })
  end

  defp property(%Argument{type: :object, properties: nil} = argument) do
    %{
      "type" => "object",
      "description" => argument.description,
      "additionalProperties" => true
    }
  end

  defp property(%Argument{type: :object, properties: properties} = argument) do
    %{
      "type" => "object",
      "description" => argument.description,
      "properties" => Map.new(properties, &{&1.name, property(&1)}),
      # Open, unlike a method's own arguments: these objects are specs and documents that
      # carry more than Troupe names, and refusing an unknown key would refuse a field the
      # cluster understands.
      "additionalProperties" => true
    }
  end

  # The only arrays in the surface are lists of names.
  defp property(%Argument{type: :array} = argument) do
    %{
      "type" => "array",
      "description" => argument.description,
      "items" => %{"type" => "string"}
    }
  end

  defp property(%Argument{values: values} = argument) when is_list(values) do
    %{"type" => to_string(argument.type), "description" => argument.description, "enum" => values}
  end

  defp property(%Argument{} = argument) do
    %{"type" => to_string(argument.type), "description" => argument.description}
  end

  # -- JSON-RPC ---------------------------------------------------------------

  defp result(id, value), do: %{"jsonrpc" => "2.0", "id" => id, "result" => value}

  defp error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp version, do: to_string(Application.spec(:troupe_plane, :vsn) || "dev")
end
