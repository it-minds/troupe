defmodule Troupe.Gateway.ClientTool do
  @moduledoc """
  Running a tool that lives on somebody's laptop, from inside the agent's tool task.

  The call goes out over the connection that registered the tool — a server-to-client
  `tool.invoke` — and this function blocks on the answer. It is only ever called from a
  task under the agent's `Agent.Tasks` supervisor, so blocking here costs one task and
  the agent goes on collecting other results meanwhile.

  Two failures matter and they are different.

  **The registrant disconnects.** Knowable immediately: the connection process is gone,
  the `GenServer.call` exits, and that becomes an error result the model can read. Making
  the agent wait out the tool timeout for news that has already arrived would turn a
  dropped laptop into a hung turn, which is the thing the done item is about.

  **The registrant does not answer.** Indistinguishable from a wedged laptop, so it is
  bounded by the tool's own timeout and becomes the same kind of error result. The call
  is abandoned rather than cancelled: a client that answers afterwards finds nobody
  waiting, which is handled where the answer arrives.
  """

  alias Troupe.Gateway.Connection
  alias Troupe.Tool.Ctx

  @doc "Invoke one client-hosted tool and turn whatever happens into a tool result."
  @spec run(pid(), String.t(), map(), Ctx.t()) :: {:ok, String.t()} | {:error, term()}
  def run(connection, name, args, %Ctx{} = ctx) do
    case Connection.invoke_tool(connection, ctx.call_id, prefixed(name), args, ctx.timeout_ms) do
      {:ok, result} -> {:ok, content(result)}
      {:error, :disconnected} -> {:error, disconnected(name)}
      {:error, :timeout} -> {:error, {:timeout, ctx.timeout_ms}}
      {:error, %{message: message}} -> {:error, "#{name} failed on the client: #{message}"}
      {:error, reason} -> {:error, "#{name} failed on the client: #{inspect(reason)}"}
    end
  end

  defp disconnected(name) do
    "The client hosting #{name} disconnected before answering. " <>
      "That tool is gone for this session; do the work another way."
  end

  # A client may answer with prose, with MCP-shaped content blocks, or with a bare
  # object. All three are the same thing to the model, so all three are rendered rather
  # than one being accepted and the others refused.
  defp content(%{"content" => text}) when is_binary(text), do: text

  defp content(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      other -> Jason.encode!(other)
    end)
    |> Enum.join("\n")
  end

  defp content(result) when is_map(result), do: Jason.encode!(result)
  defp content(other), do: to_string(other)

  defp prefixed("client." <> _rest = name), do: name
  defp prefixed(name), do: "client." <> name
end
