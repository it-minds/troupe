defmodule Troupe.Plane.FakePod do
  @moduledoc """
  A worker that enrols for real over the control channel and forwards every push to a
  test process, so assertions are about what actually crossed the wire.

  Every request the plane pushes is answered `{"ok": true}` — or, for a method named in
  `refuse:`, with the error object given for it; notifications are forwarded and not
  answered. The test receives `{:pushed, method, params}` for both. A method named in
  `hold:` is not answered until the test says so: it receives
  `{:held, method, params, answer}` instead and calls `answer.()`, and the pod goes on
  answering everything else meanwhile.

  The token it sends carries this VM's own mark, and `verify/1` takes no token without it.
  Every worker suite's link enrols as `troupe-w-dev-0` with `dev-token` too, and redials
  every quarter second to two seconds once its plane has gone; another suite on the same
  machine (another checkout's) can reach a port the system has since handed this suite's
  listener. Taken, the stranger was the newer connection under the pod's name, and the
  plane dropped the fake pod's, before its enrolment was answered or in the middle of a
  test.
  """

  @doc "Enrol a pod on a listener port with a token the test's verifier accepts."
  @spec enrol(:inet.port_number(), String.t(), String.t(), keyword()) ::
          %{worker_id: String.t(), socket: port()}
  def enrol(port, token, pod_name, opts \\ []) do
    test = Keyword.get(opts, :notify, self())
    refuse = Keyword.get(opts, :refuse, %{})
    hold = Keyword.get(opts, :hold, [])
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    request =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "enrol",
        "params" => %{
          "token" => token(token),
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
        serve(socket, test, refuse, hold)
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    ExUnit.Callbacks.on_exit(fn -> :gen_tcp.close(socket) end)

    %{worker_id: result["worker_id"], socket: socket}
  end

  @doc """
  The verifier a test hands the listener: `<profile>-token`, as `enrol/4` sends it with
  this VM's mark, enrols on `<profile>`.
  """
  @spec verify(String.t()) :: {:ok, map()} | {:error, :unauthenticated}
  def verify(token) do
    mark = mark()

    case String.split(token, "-token") do
      [profile, ^mark] ->
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

  @doc "Tell the plane something as the pod, a notification it does not answer."
  @spec say(%{socket: port()}, String.t(), map()) :: :ok | {:error, term()}
  def say(%{socket: socket}, method, params) do
    notification = Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params})
    :gen_tcp.send(socket, [notification, ?\n])
  end

  @doc "A token as `enrol/4` sends it, for a test that speaks the control channel itself."
  @spec token(String.t()) :: String.t()
  def token(token), do: token <> mark()

  # This VM's operating-system process, which no other VM on the machine has while it runs.
  defp mark, do: "." <> System.pid()

  defp answer(id, method, refuse) do
    case Map.get(refuse, method) do
      nil -> Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"ok" => true}})
      error -> Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => error})
    end
  end

  defp serve(socket, test, refuse, hold) do
    receive do
      {:tcp, ^socket, data} ->
        for line <- String.split(data, "\n", trim: true),
            do: handle(Jason.decode(line), socket, test, refuse, hold)

        serve(socket, test, refuse, hold)

      {:answer, id, method} ->
        :gen_tcp.send(socket, [answer(id, method, refuse), ?\n])
        serve(socket, test, refuse, hold)

      {:tcp_closed, ^socket} ->
        :ok
    end
  end

  defp handle(
         {:ok, %{"id" => id, "method" => method, "params" => params}},
         socket,
         test,
         refuse,
         hold
       ) do
    if method in hold do
      pod = self()
      send(test, {:held, method, params, fn -> send(pod, {:answer, id, method}) end})
    else
      send(test, {:pushed, method, params})
      :gen_tcp.send(socket, [answer(id, method, refuse), ?\n])
    end
  end

  defp handle({:ok, %{"method" => method, "params" => params}}, _socket, test, _refuse, _hold),
    do: send(test, {:pushed, method, params})

  defp handle(_other, _socket, _test, _refuse, _hold), do: :ok
end
