defmodule Troupe.Plane.FakePod do
  @moduledoc """
  A worker that enrols for real over the control channel and forwards every push to a
  test process, so assertions are about what actually crossed the wire.

  Every request the plane pushes is answered `{"ok": true}`; notifications are forwarded
  and not answered. The test receives `{:pushed, method, params}` for both.
  """

  @doc "Enrol a pod on a listener port with a token the test's verifier accepts."
  @spec enrol(:inet.port_number(), String.t(), String.t(), keyword()) ::
          %{worker_id: String.t(), socket: port()}
  def enrol(port, token, pod_name, opts \\ []) do
    test = Keyword.get(opts, :notify, self())
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    request =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "enrol",
        "params" => %{
          "token" => token,
          "pod_name" => pod_name,
          "capacity" => Keyword.get(opts, :capacity, 4),
          "disk_total_bytes" => 1_000_000
        }
      })

    :ok = :gen_tcp.send(socket, [request, ?\n])
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)

    %{"result" => result} =
      line |> String.split("\n", trim: true) |> List.first() |> Jason.decode!()

    pid =
      spawn_link(fn ->
        :inet.setopts(socket, active: true)
        serve(socket, test)
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    ExUnit.Callbacks.on_exit(fn -> :gen_tcp.close(socket) end)

    %{worker_id: result["worker_id"], socket: socket}
  end

  @doc "The verifier a test hands the listener: `<profile>-token` enrols on `<profile>`."
  @spec verify(String.t()) :: {:ok, map()} | {:error, :unauthenticated}
  def verify(token) do
    case String.split(token, "-token") do
      [profile, ""] ->
        {:ok,
         %{
           profile: profile,
           namespace: "troupe-w-#{profile}",
           pod_name: nil,
           service_account: "troupe-worker"
         }}

      _ ->
        {:error, :unauthenticated}
    end
  end

  defp serve(socket, test) do
    receive do
      {:tcp, ^socket, data} ->
        for line <- String.split(data, "\n", trim: true) do
          case Jason.decode(line) do
            {:ok, %{"id" => id, "method" => method, "params" => params}} ->
              send(test, {:pushed, method, params})

              answer =
                Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"ok" => true}})

              :gen_tcp.send(socket, [answer, ?\n])

            {:ok, %{"method" => method, "params" => params}} ->
              send(test, {:pushed, method, params})

            _ ->
              :ok
          end
        end

        serve(socket, test)

      {:tcp_closed, ^socket} ->
        :ok
    end
  end
end
