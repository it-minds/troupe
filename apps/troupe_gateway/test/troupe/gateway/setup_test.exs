defmodule Troupe.Gateway.SetupTest do
  @moduledoc """
  `setup.get` and `setup.answer` through the daemon's own socket (Decision 705): a
  client drives the first run to a written file, a record and a first session, the key
  never comes back, and a worker does not answer them at all.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, Dispatch}
  alias Troupe.Protocol.{Client, Endpoint, Error}

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY
           TROUPE_AUTH_TOKEN TROUPE_PROVIDER TROUPE_MODEL ANTHROPIC_API_KEY OPENAI_API_KEY)

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-gw-setup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "config"))
    File.mkdir_p!(Path.join(base, "state"))
    File.mkdir_p!(Path.join(base, "project"))

    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
    System.put_env("TROUPE_STATE_HOME", Path.join(base, "state"))
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "none.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "none.json"))

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm_rf!(base)
    end)

    %{
      base: base,
      workspace: Path.join(base, "project"),
      config_file: Path.join([base, "config", "config.yaml"])
    }
  end

  describe "on the daemon" do
    setup %{base: base} do
      endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
      start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})
      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)
      %{client: client}
    end

    test "a client drives the first run to a session, and the key never comes back", ctx do
      assert {:ok, %{"needed" => true, "step" => "where", "completed" => nil} = report} =
               Client.call(ctx.client, "setup.get", %{})

      assert report["key_storage"] == %{
               "kind" => "file",
               "path" => Troupe.Paths.display(ctx.config_file),
               "keychain" => false
             }

      assert report["detected"]["env"] == []

      assert {:ok, %{"step" => "provider"}} =
               answer(ctx.client, "c-1", "where", %{"choice" => "local"})

      assert {:ok, %{"step" => "key"}} =
               answer(ctx.client, "c-2", "provider", %{"provider" => "fake"})

      assert {:ok, %{"step" => "key", "check" => %{"state" => "refused"}}} =
               answer(ctx.client, "c-3", "key", %{"api_key" => "bad-key"})

      assert {:ok,
              %{"step" => "models", "check" => %{"state" => "ok"}, "suggested" => suggested} =
                checked} =
               answer(ctx.client, "c-4", "key", %{"api_key" => "sk-typed-into-a-form"})

      refute inspect(checked) =~ "sk-typed-into-a-form"
      assert checked["answers"]["key"] == %{"source" => "typed"}

      assert {:ok, %{"step" => "workspace"}} = answer(ctx.client, "c-5", "models", suggested)
      assert File.read!(ctx.config_file) =~ "sk-typed-into-a-form"

      assert {:ok, %{"step" => "finish", "suggested_prompt" => prompt}} =
               answer(ctx.client, "c-6", "workspace", %{
                 "workspace" => ctx.workspace,
                 "approvals" => "ask"
               })

      assert is_binary(prompt)

      assert {:ok, %{"step" => "done", "session" => session}} =
               answer(ctx.client, "c-7", "finish", %{})

      assert %{"session_id" => session_id, "workspace" => workspace, "prompt" => ^prompt} =
               session

      assert workspace == ctx.workspace

      assert {:ok, %{"sessions" => sessions}} =
               Client.call(ctx.client, "session.list", %{"filter" => %{}})

      assert Enum.any?(sessions, &(&1["id"] == session_id))

      # Done, for every client: the next read is a fresh flow that is not needed.
      assert {:ok, %{"needed" => false, "step" => "where", "completed" => %{"choice" => "local"}}} =
               Client.call(ctx.client, "setup.get", %{})
    end

    test "a bad answer is invalid_params with the reason, and the flow stays where it was", ctx do
      assert {:error, %Error{message: "invalid_params", data: data}} =
               answer(ctx.client, "c-1", "where", %{"choice" => "cloud"})

      assert data["reason"] == "choice must be local or plane"

      assert {:error, %Error{message: "invalid_params", data: data}} =
               answer(ctx.client, "c-2", "provider", %{"provider" => "fake"})

      assert data["reason"] =~ "the current step is where"
      assert {:ok, %{"step" => "where"}} = Client.call(ctx.client, "setup.get", %{})
    end

    test "a plane is recorded and starts nothing", ctx do
      assert {:ok, %{"step" => "finish"}} =
               answer(ctx.client, "c-1", "where", %{"choice" => "plane"})

      assert {:ok, %{"step" => "done", "session" => nil}} =
               answer(ctx.client, "c-2", "finish", %{})

      assert {:ok, %{"needed" => false, "completed" => %{"choice" => "plane"}}} =
               Client.call(ctx.client, "setup.get", %{})

      refute File.exists?(ctx.config_file)
    end
  end

  # A pod runs the same dispatcher without the daemon: there is nothing to set up there.
  test "without the daemon, the methods do not exist" do
    context = %Dispatch.Context{
      principal: %{"subject" => "someone"},
      scopes: [:observe, :control, :admin],
      connection: self()
    }

    refute Process.whereis(Daemon)

    assert {:error, %Error{message: "method_not_found"}} =
             Dispatch.call("setup.get", %{}, context)

    assert {:error, %Error{message: "method_not_found"}} =
             Dispatch.call("setup.answer", %{"command_id" => "c", "step" => "where"}, context)
  end

  defp answer(client, command_id, step, answer) do
    Client.call(client, "setup.answer", %{
      "command_id" => command_id,
      "step" => step,
      "answer" => answer
    })
  end
end
