defmodule Troupe.Worker.ConfigExplainTest do
  @moduledoc """
  A session on a pod explains its configuration over its own connection, as `troupe
  config --explain` explains a laptop's: `config.get` naming the session answers what is in
  force in it, each value and rule with where it came from. That is the worker profile's
  settings (its environment) and rules, what the platform enforces, the terms the session
  was created with, and its repository's files, which a pod trusts with no gated key.

  Driven the way a pod is: `session.activate` from the plane, then a client with the
  session's own token on the pod's socket, through the guard.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.Plane.Tokens
  alias Troupe.Protocol.Client
  alias Troupe.Protocol.Endpoint
  alias Troupe.Worker.Auth
  alias Troupe.Worker.Plane.Commands

  @moduletag timeout: 120_000

  @pod "worker-dev-0"

  @rules [
    %{"action" => "deny", "rule" => "shell(curl)", "profile" => "standard"},
    %{"action" => "allow", "rule" => "shell(git status)", "profile" => "fixing"}
  ]

  setup context do
    context = requires_tier(context)

    start_supervised!(Troupe.Gateway.Connections)
    start_supervised!(Troupe.Gateway.Commands)

    {:ok, jwks} = Tokens.jwks()
    auth = start_supervised!({Auth, name: nil, worker_id: @pod, jwks: jwks})

    # The profile's `llm`, which the operator writes into the pod's environment.
    previous = System.get_env("TROUPE_SMALL_MODEL")
    System.put_env("TROUPE_SMALL_MODEL", "profile-cheap-model")
    previous_url = System.get_env("TROUPE_BASE_URL")
    System.put_env("TROUPE_BASE_URL", "http://llm.example.test/v1")

    # The repository's own file: a key it may set, and one a pod never takes from it.
    File.mkdir_p!(Path.join(context.workspace, ".troupe"))

    File.write!(
      Path.join([context.workspace, ".troupe", "config.yaml"]),
      "compact_at: 0.6\nauto_approve: true\n"
    )

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_SMALL_MODEL", previous),
        else: System.delete_env("TROUPE_SMALL_MODEL")

      if previous_url,
        do: System.put_env("TROUPE_BASE_URL", previous_url),
        else: System.delete_env("TROUPE_BASE_URL")

      Application.delete_env(:troupe_worker, :session_defaults)
      quieten(context.session_id)
    end)

    Map.merge(context, %{port: start_harness!(auth)})
  end

  test "config.get naming the session says what is in force in it, and where each part came from",
       context do
    activate!(context)

    {:ok, client} = connect(context, token(context, context.session_id))
    on_exit(fn -> Client.close(client) end)

    assert {:ok, answer} =
             Client.call(client, "config.get", %{"session_id" => context.session_id})

    assert answer["session_id"] == context.session_id
    assert answer["pod"] == true
    assert answer["trusted"] == false
    keys = Map.new(answer["keys"], &{&1["key"], &1})

    # The worker profile's settings, its environment, named as the profile's.
    assert %{"value" => "profile-cheap-model", "layer" => "profile", "source" => source} =
             keys["models.cheap"]

    assert source == "the worker profile fixing (TROUPE_SMALL_MODEL)"

    # The terms the session was created with.
    assert %{"value" => 7, "layer" => "session", "source" => "the session's terms"} =
             keys["max_turns"]

    assert %{"value" => "deny", "layer" => "session"} = keys["approvals"]

    # What the platform enforces, which nobody writes from here.
    assert %{"value" => true, "layer" => "enforced", "scopes" => []} =
             keys["managed_permission_rules_only"]

    assert keys["managed_permission_rules_only"]["enforced"]["source"] ==
             "the plane's platform settings"

    # The repository's file: what it may set is in force, what it may not on a pod is not.
    assert %{"value" => 0.6, "layer" => "project"} = keys["compact_at"]
    refute keys["auto_approve"]["layer"] == "project"
    assert Enum.any?(answer["warnings"], &(&1 =~ "auto_approve"))

    # Nothing on a pod is a client's to write.
    assert Enum.all?(answer["keys"], &(&1["scopes"] == []))

    # The profile's rules, each with the profile that wrote it.
    rules = Enum.filter(answer["permissions"], &(&1["scope"] == "profile"))

    assert Enum.sort_by(rules, & &1["rule"]) == [
             %{
               "action" => "deny",
               "rule" => "shell(curl)",
               "tool" => "shell",
               "pattern" => "curl",
               "scope" => "profile",
               "source" => "standard",
               "ignored" => nil
             },
             %{
               "action" => "allow",
               "rule" => "shell(git status)",
               "tool" => "shell",
               "pattern" => "git status",
               "scope" => "profile",
               "source" => "fixing",
               "ignored" => nil
             }
           ]
  end

  test "explain answers what troupe config --explain prints for the session, and its JSON",
       context do
    activate!(context)

    {:ok, client} = connect(context, token(context, context.session_id))
    on_exit(fn -> Client.close(client) end)

    assert {:ok, %{"explain" => text, "explain_status" => 0}} =
             Client.call(client, "config.get", %{
               "session_id" => context.session_id,
               "explain" => "text"
             })

    assert text =~ "configuration in force in session #{context.session_id}, on a worker pod"
    assert text =~ ~r/max_turns\s+7\s+session/
    assert text =~ ~r/models\.cheap\s+profile-cheap-model\s+profile/
    assert text =~ ~r/deny\s+shell\(curl\)\s+profile\s+standard/

    assert {:ok, %{"explain" => ladder}} =
             Client.call(client, "config.get", %{
               "session_id" => context.session_id,
               "explain" => "text",
               "key" => "max_turns"
             })

    assert ladder =~ ~r/session\s+7\s+the session's terms  <- in effect/

    assert {:ok, %{"explain" => json}} =
             Client.call(client, "config.get", %{
               "session_id" => context.session_id,
               "explain" => "json"
             })

    assert json["session_id"] == context.session_id
    assert json["pod"] == true
    assert Enum.any?(json["keys"], &(&1["key"] == "max_turns" and &1["layer"] == "session"))
  end

  test "a viewer is not shown what the session runs on: the provider's address and the state directory",
       context do
    activate!(context)

    {:ok, viewer} = connect(context, token(context, context.session_id))
    on_exit(fn -> Client.close(viewer) end)

    assert {:ok, answer} =
             Client.call(viewer, "config.get", %{"session_id" => context.session_id})

    keys = Map.new(answer["keys"], &{&1["key"], &1})

    for key <- ["base_url", "state_dir"] do
      assert %{"value" => "set by the profile", "withheld" => true} = keys[key]
    end

    # Where they came from is still said, and the rest is as a collaborator sees it.
    assert keys["base_url"]["layer"] == "profile"
    assert keys["models.cheap"]["value"] == "profile-cheap-model"
    assert Enum.any?(answer["permissions"], &(&1["rule"] == "shell(curl)"))

    for form <- ["text", "json"] do
      assert {:ok, %{"explain" => explained}} =
               Client.call(viewer, "config.get", %{
                 "session_id" => context.session_id,
                 "explain" => form
               })

      printed = if is_binary(explained), do: explained, else: Jason.encode!(explained)
      refute printed =~ "llm.example.test"
      refute printed =~ context.state_dir
      assert printed =~ "set by the profile"
    end

    assert {:ok, %{"explain" => ladder}} =
             Client.call(viewer, "config.get", %{
               "session_id" => context.session_id,
               "explain" => "text",
               "key" => "base_url"
             })

    refute ladder =~ "llm.example.test"
    assert ladder =~ "base_url = set by the profile"

    # Someone who may steer it sees them.
    {:ok, collaborator} = connect(context, token(context, context.session_id, "collaborator"))
    on_exit(fn -> Client.close(collaborator) end)

    assert {:ok, steering} =
             Client.call(collaborator, "config.get", %{
               "session_id" => context.session_id,
               "explain" => "text"
             })

    keys = Map.new(steering["keys"], &{&1["key"], &1})
    assert keys["base_url"]["value"] == "http://llm.example.test/v1"
    refute Map.has_key?(keys["base_url"], "withheld")
    assert keys["state_dir"]["value"] == context.state_dir
    assert steering["explain"] =~ "llm.example.test"
  end

  test "a session's token is refused the pod's own settings, and another session's", context do
    activate!(context)
    other = Troupe.Session.generate_id()

    {:ok, client} = connect(context, token(context, context.session_id))
    on_exit(fn -> Client.close(client) end)

    assert {:error, %{message: "forbidden"} = refused} = Client.call(client, "config.get", %{})
    assert refused.data["method"] == "config.get"

    assert {:error, %{message: "forbidden"}} =
             Client.call(client, "config.get", %{"session_id" => other})
  end

  test "a session not running here is not found", context do
    asleep = Troupe.Session.generate_id()

    {:ok, client} = connect(context, token(context, asleep))
    on_exit(fn -> Client.close(client) end)

    assert {:error, %{message: "not_found"}} =
             Client.call(client, "config.get", %{"session_id" => asleep})
  end

  defp activate!(context) do
    Application.put_env(:troupe_worker, :session_defaults, activation(context))

    push = %{
      "session_id" => context.session_id,
      "team" => context.team,
      "epoch" => 1,
      "profile" => "fixing",
      "channel" => "stable",
      "terms" => %{"max_turns" => 7, "approvals" => "deny"},
      "managed" => %{"permission_rules_only" => true, "mcp_servers_only" => false},
      "permission_rules" => @rules
    }

    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)
  end

  defp start_harness!(auth) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    start_supervised!(
      {Troupe.Gateway.Listener,
       name: :"harness-#{port}",
       endpoint:
         Endpoint.remote(port, Auth.authenticator(auth),
           guard: Auth.guard(auth),
           narrow: &Auth.narrow/3
         )}
    )

    port
  end

  defp connect(context, jwt) do
    Client.connect(
      address: {127, 0, 0, 1},
      port: context.port,
      token: jwt,
      client_info: %{"name" => "test", "version" => "1"}
    )
  end

  defp token(context, session_id, role \\ "viewer") do
    claims = %{
      "sub" => "owner@example.test",
      "role" => role,
      "team" => context.team,
      "session_id" => session_id
    }

    {:ok, jwt, _payload} = Tokens.mint(claims, audience: @pod)
    jwt
  end

  defp quieten(session_id) do
    Troupe.cancel(session_id)
    Troupe.stop_session(session_id)
  catch
    :exit, _ -> :ok
  end
end
