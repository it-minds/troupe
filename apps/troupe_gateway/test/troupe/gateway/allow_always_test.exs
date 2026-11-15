defmodule Troupe.Gateway.AllowAlwaysTest do
  @moduledoc """
  "Always allow <tool>" from an approval (#920): `approval.respond` with `allow_always`
  writes the person's own rule for the tool into the file its `scope` names, answers the
  call as allowed, lets the tool through for the rest of the session, and is refused where
  the platform allows only its own rules or where an allow there would be held.
  """

  use ExUnit.Case, async: false

  alias Troupe.Config.Settings
  alias Troupe.Gateway.Daemon
  alias Troupe.Protocol.{Client, Endpoint, Error}

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH)

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-gw-always-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    Enum.each([workspace, state_dir, Path.join(base, "config")], &File.mkdir_p!/1)

    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
    System.put_env("TROUPE_STATE_HOME", state_dir)
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "none.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "none.json"))

    on_exit(fn ->
      Enum.each(previous, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)
      File.rm_rf!(base)
    end)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    %{
      base: base,
      workspace: workspace,
      state_dir: state_dir,
      endpoint: endpoint,
      user_file: Path.join([base, "config", "config.yaml"])
    }
  end

  test "the daemon names the capability", context do
    {:ok, client} = connect(context)
    assert Client.info(client).capabilities["approval_allow_always"] == true
  end

  test "everywhere writes the person's rule, allows the call, and the tool runs unasked after", context do
    steps = [
      {:text_and_tools, "writing", [{"write_file", %{"path" => "a.md", "content" => "one"}}]},
      {:text_and_tools, "again", [{"write_file", %{"path" => "b.md", "content" => "two"}}]},
      {:text, "done"}
    ]

    %{session: session} = start_session(context, steps)
    {:ok, client} = connect(context)
    {:ok, _} = Client.subscribe(client, "session:#{session.id}")
    send_input(client, session.id)

    asked = wait_for("approval_requested")
    assert asked.data["tool"] == "write_file"

    assert {:ok, %{"accepted" => true, "rule" => rule}} =
             Client.call(client, "approval.respond", respond(session.id, asked, %{"scope" => "everywhere"}))

    assert rule == %{"rule" => "write_file", "scope" => "everywhere", "path" => context.user_file}
    assert File.read!(context.user_file) =~ ~r/permissions:\s+allow:\s+- "write_file"\n/

    decided = wait_for("approval_decided")
    assert decided.data["decision"] == "allow_always"
    assert decided.data["always"] == rule
    assert decided.actor.subject

    # The second write in the same session is not asked about, and both files are there.
    events = collect_until(&(&1.type == "turn_ended"))
    refute Enum.any?(events, &(&1.type == "approval_requested"))
    assert File.read!(Path.join(context.workspace, "b.md")) == "two"

    # Announced as a `config.set` is, and listed with the rest.
    assert_receive {:troupe_notification, "config.changed", %{"keys" => keys}}, 2_000
    assert "permissions.allow" in keys

    {:ok, %{"permissions" => rules}} = Client.call(client, "config.get", %{})
    assert %{"action" => "allow", "rule" => "write_file", "scope" => "user"} = Enum.find(rules, &(&1["rule"] == "write_file"))
  end

  test "an MCP tool is kept as mcp(server.tool), and a rule already there is not written twice", context do
    assert {:ok, %{"rule" => "mcp(github.create_issue)"}} =
             Settings.allow_rule("mcp.github.create_issue", "everywhere", context.workspace)

    assert {:ok, %{"rule" => "mcp(github.create_issue)"}} =
             Settings.allow_rule("client.github.create_issue", "everywhere", context.workspace)

    text = File.read!(context.user_file)
    assert length(String.split(text, "mcp(github.create_issue)")) == 2
  end

  test "under managed_permission_rules_only it is refused, nothing is written, and the call still waits",
       context do
    steps = [
      {:text_and_tools, "writing", [{"write_file", %{"path" => "a.md", "content" => "one"}}]},
      {:text, "done"}
    ]

    %{session: session} = start_session(context, steps, managed_permission_rules_only: true)
    {:ok, client} = connect(context)
    {:ok, _} = Client.subscribe(client, "session:#{session.id}")
    send_input(client, session.id)
    asked = wait_for("approval_requested")

    assert {:error, %Error{message: "forbidden", data: data}} =
             Client.call(client, "approval.respond", respond(session.id, asked, %{}))

    assert data["setting"] == "managed_permission_rules_only"
    assert data["reason"] =~ "allows only its own permission rules"
    refute File.exists?(context.user_file)

    assert {:ok, %{"accepted" => true}} =
             Client.call(client, "approval.respond", %{respond(session.id, asked, %{}) | "decision" => "allow"})

    assert wait_for("approval_decided").data["decision"] == "allow"
  end

  test "workspace in a workspace that is not trusted is refused with what to do", context do
    steps = [
      {:text_and_tools, "writing", [{"write_file", %{"path" => "a.md", "content" => "one"}}]},
      {:text, "done"}
    ]

    %{session: session} = start_session(context, steps)
    {:ok, client} = connect(context)
    {:ok, _} = Client.subscribe(client, "session:#{session.id}")
    send_input(client, session.id)
    asked = wait_for("approval_requested")

    assert {:error, %Error{message: "invalid_params", data: %{"reason" => reason}}} =
             Client.call(client, "approval.respond", respond(session.id, asked, %{"scope" => "workspace"}))

    assert reason =~ "not a trusted workspace"
    refute File.exists?(Path.join([context.workspace, ".troupe", "config.local.yaml"]))
  end

  test "a scope that is neither is refused", context do
    assert {:error, "scope must be workspace or everywhere, not \"project\""} =
             Settings.allow_rule("shell", "project", context.workspace)
  end

  defp respond(session_id, asked, extra) do
    Map.merge(
      %{
        "command_id" => Client.command_id(),
        "session_id" => session_id,
        "call_id" => asked.data["call_id"],
        "decision" => "allow_always"
      },
      extra
    )
  end

  defp connect(context) do
    {address, port} = Endpoint.connect_args(context.endpoint)
    Client.connect(address: address, port: port, client_info: %{"name" => "test", "version" => "1"})
  end

  defp start_session(context, steps, overrides \\ []) do
    fake =
      start_supervised!({Troupe.LLM.Fake, [steps: steps]}, id: {Troupe.LLM.Fake, System.unique_integer([:positive])})

    {:ok, session} =
      Troupe.start_session(
        workspace: context.workspace,
        fake: fake,
        config_overrides: [provider: "fake", model: "fake", state_dir: context.state_dir] ++ overrides
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    %{session: session, fake: fake}
  end

  defp send_input(client, session_id) do
    {:ok, _} =
      Client.call(client, "input.send", %{
        "command_id" => Client.command_id(),
        "session_id" => session_id,
        "text" => "go"
      })
  end

  defp wait_for(type) do
    receive do
      {:troupe_event, _topic, _id, %{type: ^type} = event} -> event
    after
      8_000 -> flunk("no #{type}")
    end
  end

  defp collect_until(predicate, acc \\ []) do
    receive do
      {:troupe_event, _topic, _id, event} ->
        acc = [event | acc]
        if predicate.(event), do: Enum.reverse(acc), else: collect_until(predicate, acc)
    after
      8_000 -> Enum.reverse(acc)
    end
  end
end
