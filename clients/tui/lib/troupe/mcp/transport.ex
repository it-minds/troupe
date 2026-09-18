defmodule Troupe.MCP.Transport do
  @moduledoc """
  Behaviour for MCP transports. The owner (an `Troupe.MCP.Server`) receives
  `{:mcp_data, binary}` messages — one complete JSON-RPC message each — and
  `{:mcp_closed, reason}` when the transport goes down.
  """

  @callback start_link(owner :: pid(), config :: map()) :: GenServer.on_start()
  @callback send_message(pid(), iodata()) :: :ok
  @callback close(pid()) :: :ok
end
