defmodule Troupe.Gateway.ClientTool do
  @moduledoc """
  Running a tool that lives on somebody's laptop, from inside the agent's tool task.

  The call goes out over the connection that registered the tool — a server-to-client
  `tool.invoke` — and this function blocks on the answer. It is only ever called from a
  task under the agent's `Agent.Tasks` supervisor, so blocking here costs one task and
  the agent goes on collecting other results meanwhile.

  Two failures matter and they are different.

  **The registrant disconnects.** Knowable immediately: the connection process is gone
  and the `GenServer.call` exits. It is usually back in a moment, though — a lid closed,
  an app restarted — on a fresh connection, and it registers its tools again through a
  fresh consent. So the call is parked for a grace (`Troupe.Session.ClientTools.await/4`)
  and, when a client offers the tool again inside it, goes out over that connection as
  the same call, with what is left of its timeout. Nobody inside the grace, and the call
  fails once with a reason the model can act on: which tool, and that its client left.
  The tool is off the model's list by then. The grace comes out of the call's own timeout,
  so a dropped laptop is still never a hung turn.

  **The registrant does not answer.** Indistinguishable from a wedged laptop, so it is
  bounded by the tool's own timeout and becomes the same kind of error result. The call
  is abandoned rather than cancelled: a client that answers afterwards finds nobody
  waiting, which is handled where the answer arrives.
  """

  alias Troupe.Gateway.Connection
  alias Troupe.Session.ClientTools
  alias Troupe.Tool.Ctx

  @doc "Invoke one client-hosted tool and turn whatever happens into a tool result."
  @spec run(pid(), String.t(), map(), Ctx.t()) :: {:ok, String.t()} | {:error, term()}
  def run(connection, name, args, %Ctx{} = ctx) do
    started = now()

    case Connection.invoke_tool(connection, ctx.call_id, prefixed(name), args, ctx.timeout_ms) do
      {:ok, result} -> {:ok, content(result)}
      {:error, :disconnected} -> park(connection, name, args, ctx, started)
      {:error, :timeout} -> {:error, {:timeout, ctx.timeout_ms}}
      {:error, %{message: message}} -> {:error, "#{name} failed on the client: #{message}"}
      {:error, reason} -> {:error, "#{name} failed on the client: #{inspect(reason)}"}
    end
  end

  # The registrant left mid-call. Wait for a client to offer the tool again, for the grace
  # or for what is left of the call's timeout, whichever is shorter, and run the call
  # through the new registration's own `run/2`, which reaches the new connection and comes
  # back here if that one goes too.
  defp park(connection, name, args, ctx, started) do
    grace = min(ClientTools.grace_ms(), remaining(ctx, started))

    case ClientTools.await(ctx.session_id, prefixed(name), grace, except: connection) do
      {:ok, %{run: run}} -> run.(args, %{ctx | timeout_ms: remaining(ctx, started)})
      {:error, :gone} -> {:error, gone(name, grace)}
    end
  end

  defp remaining(ctx, started), do: max(ctx.timeout_ms - (now() - started), 0)

  defp gone(name, 0) do
    "The client hosting #{name} left mid-call. That tool is gone for this session; do the work another way."
  end

  defp gone(name, grace_ms) do
    "The client hosting #{name} left mid-call and did not come back within #{seconds(grace_ms)}. " <>
      "That tool is gone for this session; do the work another way."
  end

  defp seconds(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)} s"
  defp seconds(ms), do: "#{ms} ms"

  defp now, do: System.monotonic_time(:millisecond)

  # A client may answer with prose, with MCP-shaped content blocks, or with a bare
  # object. All three are the same thing to the model, so all three are rendered rather
  # than one being accepted and the others refused.
  defp content(%{"content" => text}) when is_binary(text), do: text

  defp content(%{"content" => blocks}) when is_list(blocks) do
    Enum.map_join(blocks, "\n", fn
      %{"text" => text} when is_binary(text) -> text
      other -> Jason.encode!(other)
    end)
  end

  defp content(result) when is_map(result), do: Jason.encode!(result)
  defp content(other), do: to_string(other)

  defp prefixed("client." <> _rest = name), do: name
  defp prefixed(name), do: "client." <> name
end
