defmodule Troupe.CrashReportTest do
  @moduledoc """
  What a crash report prints (Decision 857): a session's config, an agent's state and an
  MCP server's process hold the model's key, each named provider's key and every MCP
  server's `env` and `headers`. Their names are printed, so a report still says what was
  set; their values never are, since a log is what people attach to a bug report.

  Each process is ended with an abnormal reason, which is what makes OTP write the same
  report a crash writes, and the log is searched for the values.
  """

  # Not async: the logger's level is the whole VM's, and the crash reports need `debug`.
  use Troupe.SessionCase, async: false

  import ExUnit.CaptureLog

  alias Troupe.Config
  alias Troupe.Session.MCP

  @stub Path.expand("../support/mcp_stub.exs", __DIR__)
  @elixir System.find_executable("elixir") || "elixir"

  @model_key "sk-model-key-0f3a9c"
  @gateway_key "sk-gateway-key-7b21d4"
  @env_value "env-value-5e8c12"
  @header_value "header-value-9d4b77"
  @secrets [@model_key, @gateway_key, @env_value, @header_value]

  defp providers do
    %{
      "gw" => %{
        type: :openai,
        base_url: "http://127.0.0.1:1/v1",
        api_key: @gateway_key,
        auth: :bearer,
        models: %{},
        source: :yaml
      }
    }
  end

  defp servers do
    %{
      "stub" => %{
        command: @elixir,
        args: [@stub],
        env: %{"STUB_TOKEN" => @env_value},
        cd: nil,
        url: nil,
        permission: :ask,
        timeout_ms: 30_000
      },
      "remote" => %{
        command: nil,
        args: [],
        env: %{},
        cd: nil,
        url: "http://127.0.0.1:1/mcp",
        headers: %{"X-Api-Key" => @header_value},
        permission: :ask,
        timeout_ms: 30_000
      }
    }
  end

  defp refute_secrets(text) do
    for secret <- @secrets, do: refute(text =~ secret, "#{secret} was printed:\n#{text}")
  end

  test "inspecting a config names its keys, env and headers and prints none of their values" do
    config = %Config{api_key: @model_key, providers: providers(), mcp: servers()}
    printed = inspect(config, limit: :infinity, printable_limit: :infinity)

    refute_secrets(printed)
    assert printed =~ "%Troupe.Config{"
    assert printed =~ "api_key: :redacted"
    assert printed =~ ~s("STUB_TOKEN")
    assert printed =~ ~s("X-Api-Key")
    assert printed =~ ~s(base_url: "http://127.0.0.1:1/v1")

    # An unset key stays unset, so a report still says there was none.
    assert inspect(%Config{}) =~ "api_key: nil"

    # The config itself is untouched: the session still sends the key.
    assert config.api_key == @model_key
  end

  test "an MCP server read from a file, string keys and all, prints names only" do
    redacted =
      Config.redacted_server(%{
        "command" => "notes",
        "env" => %{"TOKEN" => @env_value},
        "headers" => %{"X-Api-Key" => @header_value}
      })

    assert redacted == %{"command" => "notes", "env" => ["TOKEN"], "headers" => ["X-Api-Key"]}
  end

  describe "a session's crash reports" do
    # Set as a person sets them, in a config file: the scratch workspace is trusted.
    setup context do
      File.mkdir_p!(Path.join(context.workspace, ".troupe"))

      File.write!(Path.join(context.workspace, ".troupe/config.yaml"), """
      api_key: #{@model_key}
      providers:
        gw:
          type: openai
          base_url: http://127.0.0.1:1/v1
          api_key: #{@gateway_key}
      mcp:
        stub:
          command: #{@elixir}
          args: ["#{@stub}"]
          env:
            STUB_TOKEN: #{@env_value}
        remote:
          url: http://127.0.0.1:1/mcp
          headers:
            X-Api-Key: #{@header_value}
      """)

      %{session: session} = start_session(context)
      wait_for_ready(session.id, "stub")
      %{session: session}
    end

    # The agent answers a request it does not know, so it is ended as a crash ends it.
    test "the root agent's names the keys and prints no value", %{session: session} do
      log = crash(Troupe.Registry.agent(session.id, ["root"]), :terminate)

      assert log =~ "api_key"
      assert log =~ "STUB_TOKEN"
      assert log =~ "X-Api-Key"
      refute_secrets(log)
    end

    # The others fail on a request they do not know, so the report's stacktrace carries the
    # state as the argument of the call that failed, as well as printing the state.
    test "the session's loop prints no value", %{session: session} do
      log = crash(Troupe.Registry.loop(session.id))

      assert log =~ "api_key"
      refute_secrets(log)
    end

    test "the session's MCP servers' holder names their env and headers and prints no value",
         %{session: session} do
      log = crash(Troupe.Registry.session_mcp(session.id))

      assert log =~ "STUB_TOKEN"
      assert log =~ "X-Api-Key"
      refute_secrets(log)
    end

    test "an MCP server on its standard streams names its env and prints no value", %{session: session} do
      log = crash(Troupe.Registry.mcp_server(session.id, "stub"))

      assert log =~ "STUB_TOKEN"
      refute_secrets(log)
    end

    test "no process of the session prints a value in its status", %{session: session} do
      pids = session.id |> Troupe.Registry.session() |> GenServer.whereis() |> tree()
      assert length(pids) > 5

      for pid <- pids, do: pid |> status() |> refute_secrets()
    end
  end

  # Ends the process as a crash does, and returns what the log said of it: `:call` with a
  # request it has no clause for, `:terminate` through `:sys`, which writes the same report.
  # A report prints the process's state only when the logger's level is `debug`, which is
  # the level a person turns on to report a bug; the suite's is `critical`, so it is
  # lowered for the report and put back.
  defp crash(name, how \\ :call) do
    pid = GenServer.whereis(name)
    assert is_pid(pid)
    ref = Process.monitor(pid)
    level = Logger.level()

    log =
      try do
        Logger.configure(level: :debug)

        capture_log(fn ->
          case how do
            :call -> spawn(fn -> GenServer.call(pid, :not_a_request) end)
            :terminate -> spawn(fn -> :sys.terminate(pid, :boom) end)
          end

          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
          # The report is written before the process goes; give the handler a moment.
          Process.sleep(200)
        end)
      after
        Logger.configure(level: level)
      end

    assert log =~ "terminating"
    assert log =~ "State: "
    if how == :call, do: assert(log =~ "FunctionClauseError")
    log
  end

  defp tree(pid) do
    children =
      if supervisor?(pid) do
        pid
        |> Supervisor.which_children()
        |> Enum.flat_map(fn
          {_id, child, _type, _modules} when is_pid(child) -> tree(child)
          _other -> []
        end)
      else
        []
      end

    [pid | children]
  end

  defp supervisor?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        match?(
          {module, _, _} when module in [:supervisor, DynamicSupervisor],
          dictionary[:"$initial_call"]
        )

      nil ->
        false
    end
  end

  # A task answers no system message, so one that does not answer is passed over.
  defp status(pid) do
    pid |> :sys.get_status(1_000) |> inspect(limit: :infinity, printable_limit: :infinity)
  catch
    :exit, _ -> ""
  end

  defp wait_for_ready(session_id, name, waited \\ 0) do
    entry = Enum.find(MCP.status(session_id), &(&1.name == name))

    cond do
      entry && entry.state == :ready -> entry
      waited < 20_000 -> Process.sleep(100) && wait_for_ready(session_id, name, waited + 100)
      true -> flunk("#{name} never became ready: #{inspect(entry)}")
    end
  end
end
