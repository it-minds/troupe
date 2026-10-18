defmodule Troupe.Gateway.Remote.Viewer do
  @moduledoc """
  One remote person's frames, between the plane's relay and their connection here.

  The same two-process shape as `Troupe.Gateway.Web.Socket`: this process owns the
  frames and nothing else, and a `Troupe.Gateway.Connection` on a `:relay` endpoint is
  the protocol. A frame from the plane becomes `{:transport_data, text}`; a write comes
  back as `{:transport_out, iodata}` and goes up the daemon's one connection to the plane
  as `relay.frame`, named by this viewer. Neither side waits on the other, and the two
  die together.
  """

  use GenServer, restart: :temporary

  alias Troupe.Gateway.Connections
  alias Troupe.Protocol.Client

  @max_message_bytes 16 * 1024 * 1024

  @spec start(String.t(), pid(), Troupe.Protocol.Endpoint.t()) :: GenServer.on_start()
  def start(id, link, endpoint), do: GenServer.start(__MODULE__, {id, link, endpoint})

  @doc "A message from the remote person, as the plane relayed it."
  @spec frame(pid(), String.t()) :: :ok
  def frame(pid, data) do
    send(pid, {:frame, data})
    :ok
  end

  @doc "End this view, saying why to the person's connection."
  @spec close(pid(), String.t()) :: :ok
  def close(pid, reason) do
    send(pid, {:close, reason})
    :ok
  end

  @impl GenServer
  def init({id, link, endpoint}) do
    Process.set_label({"troupe remote viewer", id})

    # A remote person's client is held to a pod socket's ceiling, which the plane's relay
    # socket takes, and `initialize` says so.
    attach = [transport: {:relay, self()}, endpoint: endpoint, max_message_bytes: @max_message_bytes]

    case Connections.attach(attach) do
      {:ok, connection} ->
        monitor = Process.monitor(connection)
        send(connection, :socket_ready)
        {:ok, %{id: id, link: link, connection: connection, monitor: monitor}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  # A frame is one message; the connection reads lines, and JSON outside a string has no
  # newline that is not whitespace, so a space stands in for each.
  def handle_info({:frame, data}, state) when is_binary(data) do
    send(state.connection, {:transport_data, String.replace(data, "\n", " ") <> "\n"})
    {:noreply, state}
  end

  def handle_info({:transport_out, iodata}, state) do
    data = iodata |> IO.iodata_to_binary() |> String.trim_trailing("\n")
    Client.notify(state.link, "relay.frame", %{"viewer" => state.id, "data" => data})
    {:noreply, state}
  end

  def handle_info(:transport_close, state), do: {:stop, :normal, state}

  def handle_info({:close, reason}, state), do: {:stop, {:shutdown, reason}, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state),
    do: {:stop, :normal, %{state | connection: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  # However this view ends, its connection ends with it.
  @impl GenServer
  def terminate(reason, %{connection: connection}) when is_pid(connection) do
    send(connection, {:transport_closed, reason})
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
