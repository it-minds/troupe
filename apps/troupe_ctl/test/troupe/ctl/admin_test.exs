defmodule Troupe.Ctl.AdminTest do
  @moduledoc """
  `troupe admin`, against a mock plane.

  The CLI is a third client of the same API, so what is tested here is the part that is
  its own: that a command reaches the right method with the right parameters, that a file
  argument is read as JSON, and that an error from the plane comes out as something a
  person can act on rather than a tuple.
  """

  use ExUnit.Case, async: false

  alias Troupe.Ctl.Admin

  @moduletag timeout: 60_000

  setup do
    test = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)
    answers = :ets.new(:answers, [:public, :set])
    :ets.insert(answers, {:answer, {:result, %{"ok" => true}}})

    spawn_link(fn -> serve(listener, test, answers) end)
    on_exit(fn -> :gen_tcp.close(listener) end)

    credentials = %{"plane" => "http://127.0.0.1:#{port}"}

    %{answers: answers, credentials: credentials, port: port}
  end

  describe "commands" do
    test "each one reaches its method", context do
      for {words, method, args, _help} <- Admin.commands() do
        invocation = Enum.join(words ++ placeholders(args), " ")
        assert 0 = run(context, words ++ placeholders(args))

        assert_receive {:rpc, request}, 5_000, "no request for `troupe admin #{invocation}`"
        assert request["method"] == method
      end
    end

    test "the longest match wins", context do
      assert 0 = run(context, ~w(team admin add engineering somebody@example.test))
      assert_receive {:rpc, request}, 5_000

      # Not `team` with three arguments.
      assert request["method"] == "admin.team.admin.add"
      assert request["params"]["name"] == "engineering"
      assert request["params"]["subject"] == "somebody@example.test"
    end

    test "a missing argument is a usage error, not a request", context do
      assert 2 = run(context, ~w(profile show))
      refute_receive {:rpc, _request}, 200
    end

    test "an unknown command prints the list", context do
      assert 2 = run(context, ~w(nonsense))
      refute_receive {:rpc, _request}, 200
    end
  end

  describe "file arguments" do
    test "are read as JSON and sent as the body", context do
      path = Path.join(System.tmp_dir!(), "profile-#{System.unique_integer([:positive])}.json")
      File.write!(path, ~s({"name": "dev", "replicas": 3}))
      on_exit(fn -> File.rm(path) end)

      assert 0 = run(context, ["profile", "put", path])

      assert_receive {:rpc, request}, 5_000
      assert request["params"]["profile"] == %{"name" => "dev", "replicas" => 3}
    end

    test "a file that is not there is said so, without a request", context do
      assert 2 = run(context, ~w(profile put /nowhere/at/all.json))
      refute_receive {:rpc, _request}, 200
    end

    test "a file that is not a JSON object is said so", context do
      path = Path.join(System.tmp_dir!(), "bad-#{System.unique_integer([:positive])}.json")
      File.write!(path, "[1, 2, 3]")
      on_exit(fn -> File.rm(path) end)

      assert 2 = run(context, ["profile", "put", path])
    end
  end

  describe "what comes back" do
    test "a refusal is a sentence, not a tuple", context do
      :ets.insert(
        context.answers,
        {:answer,
         {:error, %{"message" => "forbidden", "data" => %{"required_role" => "platform_admin"}}}}
      )

      output = capture(fn -> assert 1 = run(context, ~w(profiles)) end)

      assert output =~ "forbidden"
      assert output =~ "platform_admin"
    end

    test "not being logged in says what to do about it", _context do
      output =
        capture(fn ->
          assert 1 = Admin.safe(~w(profiles), credentials: nil, token: "unused")
        end)

      assert output =~ "not logged in"
      assert output =~ "troupe login"
    end
  end

  test "the usage lists every command with its arguments" do
    usage = Admin.usage()

    for {words, _method, args, help} <- Admin.commands() do
      assert usage =~ Enum.join(words, " ")
      assert usage =~ help

      # A required argument is shown in capitals; one that may be left out, in brackets.
      for argument <- args do
        case String.split(argument, "?") do
          [name, ""] -> assert usage =~ "[#{String.upcase(name)}]"
          [name] -> assert usage =~ String.upcase(name)
        end
      end
    end

    # And says the thing that makes this CLI trustworthy.
    assert usage =~ "public API"
  end

  # -- helpers ----------------------------------------------------------------

  defp run(context, argv) do
    capture_silently(fn ->
      Admin.safe(argv, credentials: context.credentials, token: "a-token")
    end)
  end

  defp placeholders(args), do: Enum.map(args, &placeholder/1)

  defp placeholder("file") do
    path = Path.join(System.tmp_dir!(), "arg-#{System.unique_integer([:positive])}.json")
    File.write!(path, ~s({"name": "x"}))
    path
  end

  defp placeholder(_name), do: "x"

  defp capture(fun) do
    ExUnit.CaptureIO.capture_io(:stderr, fn -> ExUnit.CaptureIO.capture_io(fun) end)
  end

  defp capture_silently(fun) do
    result = :erlang.make_ref()
    parent = self()

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      ExUnit.CaptureIO.capture_io(fn -> send(parent, {result, fun.()}) end)
    end)

    receive do
      {^result, value} -> value
    after
      0 -> 1
    end
  end

  # -- a mock plane -----------------------------------------------------------

  defp serve(listener, test, answers) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> handle(socket, test, answers) end)
        serve(listener, test, answers)

      {:error, _reason} ->
        :ok
    end
  end

  defp handle(socket, test, answers) do
    with {:ok, raw} <- read(socket),
         [_head, body] <- String.split(raw, "\r\n\r\n", parts: 2),
         {:ok, request} <- Jason.decode(body) do
      send(test, {:rpc, request})
      :gen_tcp.send(socket, response(answers))
    end

    :gen_tcp.close(socket)
  end

  defp response(answers) do
    # One key, replaced rather than added to: two rows would make which answer the server
    # gives depend on ETS ordering, which is a test that passes for reasons of its own.
    payload =
      case :ets.lookup(answers, :answer) do
        [{:answer, {:error, error}}] -> %{"jsonrpc" => "2.0", "id" => 1, "error" => error}
        [{:answer, {:result, result}}] -> %{"jsonrpc" => "2.0", "id" => 1, "result" => result}
      end

    body = Jason.encode!(payload)

    [
      "HTTP/1.1 200 OK\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]
  end

  defp read(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data
        if complete?(acc), do: {:ok, acc}, else: read(socket, acc)

      {:error, _reason} ->
        :error
    end
  end

  defp complete?(request) do
    case String.split(request, "\r\n\r\n", parts: 2) do
      [head, body] -> byte_size(body) >= length_of(head)
      _ -> false
    end
  end

  defp length_of(head) do
    head
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(String.downcase(line), ": ", parts: 2) do
        ["content-length", value] -> String.to_integer(String.trim(value))
        _ -> nil
      end
    end)
  end
end
