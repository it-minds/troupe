defmodule Troupe.Remote.Offer do
  @moduledoc """
  The person's own signed-in MCP servers, offered to one session on a pod (root Decision
  748, PROTOCOL.md section 8): what `Troupe.Remote.Worker` keeps about it for one
  attachment, and the daemon calls it makes.

  A server the person signed in to acts as them, and the sign-in is the daemon's: it
  stays in the daemon's state directory and no pod ever holds it. The worker asks the
  daemon for the servers' tools (`mcp.list`, `mcp.tools`), registers them with the
  session (`tools.register`, with its consent round trip), and serves each `tool.invoke`
  the pod sends for one by asking the daemon to make the call (`mcp.call`). The pod sees
  names, descriptions, schemas, the arguments and what came back.

  The person is asked once for each attachment. A registration goes with the socket that
  made it, so each new socket is offered the tools again; the session's fresh challenge is
  answered with the consent already given for the same tools, and a no holds for them. A
  different set of tools is asked about again. The daemon calls block, so the worker
  makes them from a task, never from its own process.
  """

  alias Troupe.Client.Daemon.Link

  defstruct tools: [],
            routes: %{},
            key: nil,
            servers: [],
            allowed: nil,
            declined: nil,
            registered: nil,
            asking: nil

  @typedoc "One tool as the session is offered it, and where its calls go."
  @type offered :: %{spec: map(), server: String.t(), tool: String.t()}

  @typedoc """
  `key` names the set of tools listed last; `allowed`, `declined` and `registered` the set
  the person allowed, turned down, and the one last registered. `asking` is the question
  out to the person: its call id in the window, the set it is about, and the session's
  newest challenge and words for it.
  """
  @type t :: %__MODULE__{
          tools: [map()],
          routes: %{String.t() => offered()},
          key: String.t() | nil,
          servers: [String.t()],
          allowed: String.t() | nil,
          declined: String.t() | nil,
          registered: String.t() | nil,
          asking: map() | nil
        }

  @prefix "client."

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The tools a server offers a session are named after it, so two servers' tools never meet."
  @spec name(String.t(), String.t()) :: String.t()
  def name(server, tool), do: server <> "." <> tool

  @doc """
  The person's signed-in servers' tools, as the daemon lists them with their sign-in. A
  server that is off, refused, or whose tools cannot be listed now offers nothing.
  """
  @spec collect() :: {:ok, [offered()]} | {:error, term()}
  def collect do
    case daemon("mcp.list", %{}) do
      {:ok, %{"servers" => servers}} when is_list(servers) ->
        {:ok, servers |> Enum.filter(&signed_in?/1) |> Enum.flat_map(&tools_of(&1["name"]))}

      {:ok, other} ->
        {:error, "unexpected mcp.list answer: #{inspect(other)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp signed_in?(%{"oauth" => %{}, "auth" => %{"state" => "signed_in"}} = server),
    do: server["disabled"] != true and is_nil(server["refused"])

  defp signed_in?(_server), do: false

  defp tools_of(server) do
    case daemon("mcp.tools", %{name: server}) do
      {:ok, %{"state" => "ready", "tools" => tools}} when is_list(tools) ->
        for %{"name" => tool} = listed <- tools do
          %{
            spec: %{
              name: name(server, tool),
              description: listed["description"] || "",
              schema: listed["schema"] || %{"type" => "object"}
            },
            server: server,
            tool: tool
          }
        end

      _other ->
        []
    end
  end

  @doc "The tools listed now, which the next registration offers."
  @spec put(t(), [offered()]) :: t()
  def put(%__MODULE__{} = offer, offered) do
    names = offered |> Enum.map(& &1.spec.name) |> Enum.sort()

    %{
      offer
      | tools: Enum.map(offered, & &1.spec),
        routes: Map.new(offered, &{&1.spec.name, &1}),
        key: Enum.join(names, "\n"),
        servers: offered |> Enum.map(& &1.server) |> Enum.uniq() |> Enum.sort()
    }
  end

  @doc "The tools offered, by the names the person reads."
  @spec names(t()) :: [String.t()]
  def names(%__MODULE__{routes: routes}), do: routes |> Map.keys() |> Enum.sort()

  @doc "Where a `tool.invoke` for `name` goes: the server and its own name for the tool."
  @spec route(t(), term()) :: {:ok, offered()} | :error
  def route(%__MODULE__{routes: routes}, @prefix <> name), do: Map.fetch(routes, name)
  def route(%__MODULE__{routes: routes}, name) when is_binary(name), do: Map.fetch(routes, name)
  def route(_offer, _name), do: :error

  @doc """
  One call the pod asked for, made by the daemon with the person's sign-in. The command id
  names the session and the pod's call id, so a call the pod sends again after a drop is
  answered from the daemon's first rather than made twice.
  """
  @spec call(String.t(), term(), offered(), term()) :: {:ok, map()} | {:error, String.t()}
  def call(session_id, call_id, route, arguments) do
    params = %{
      command_id: "call-#{session_id}-#{call_id}",
      name: route.server,
      tool: route.tool,
      arguments: if(is_map(arguments), do: arguments, else: %{})
    }

    case daemon("mcp.call", params) do
      {:ok, %{"content" => content}} -> {:ok, %{content: content}}
      {:ok, other} -> {:error, "unexpected mcp.call answer: #{inspect(other)}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # The daemon's link exits rather than answer when it is gone, and the caller is a task
  # that should say so rather than die of it.
  defp daemon(method, params) do
    Link.call(method, params)
  catch
    :exit, reason -> {:error, "no daemon to ask (#{inspect(reason)})"}
  end
end
