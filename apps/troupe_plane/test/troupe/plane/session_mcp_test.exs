defmodule Troupe.Plane.SessionMCPTest do
  @moduledoc """
  The platform as a tool surface, for the agent already inside it.

  Nothing let an agent in a session start a sibling without going out through the A2A
  facade — which handles the case awkwardly, because it has to mint a principal for
  Troupe to talk to itself and the session it makes then looks to the plane like a
  stranger's.

  Four tools, none destructive, all of them things the caller's own credential could do
  at `/rpc`. What is worth testing is the guardrail and the absences: a sibling may run
  what its *parent* could run rather than what the team may, nothing here can destroy
  anything, and the door's word about what is calling is the door's rather than the
  caller's.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Bundles, FakePod, Fleet, Harness, Identity, Principals, Sessions, Triggers}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Harness.MCP

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
    ada = person("ada@example.test", ["engineering"])
    _pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0", capacity: 12)

    {:ok, _profile} =
      Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable", replicas: 1})

    {:ok, _bundle} = Bundles.publish("stable", bundle_content(), announce: false)

    %{team: team, ada: ada, context: %{user: ada, platform_admin?: false}}
  end

  describe "the server" do
    test "offers four tools and nothing that destroys anything", context do
      assert %{"result" => %{"tools" => tools}} = call("tools/list", %{}, context)

      names = tools |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["session_create", "session_get", "sessions_list", "trigger_fire"]

      # The whole security argument, kept honest by a test rather than by a sentence in
      # a moduledoc: an agent that could erase a session is a blast radius nobody asked
      # for, and the way to be sure is to look at the list.
      refute Enum.any?(names, &String.contains?(&1, "erase"))
      refute Enum.any?(names, &String.contains?(&1, "delete"))
      refute Enum.any?(names, &String.contains?(&1, "revoke"))
      refute Enum.any?(names, &String.contains?(&1, "archive"))
      refute Enum.any?(names, &String.contains?(&1, "setting"))
    end

    test "says what it is, and that it is not the administrative one", context do
      assert %{"result" => result} = call("initialize", %{}, context)
      assert result["serverInfo"]["name"] == "troupe-session"
      assert result["instructions"] =~ "not an administrative interface"

      # A model that believes it can read a transcript will spend a turn looking for the
      # tool, so the instructions say so before it does.
      assert result["instructions"] =~ "Never the contents"
    end

    test "answers a tool nobody has with an error rather than a silence", context do
      assert %{"error" => %{"code" => -32_602}} =
               call("tools/call", %{"name" => "session_erase", "arguments" => %{}}, context)
    end
  end

  describe "a sibling" do
    setup context do
      {:ok, parent} = create(context, %{"profile" => "dev", "prompt" => "the parent"})
      assert_receive {:pushed, "session.activate", _}, 5_000
      %{parent: Sessions.get(parent["session_id"])}
    end

    test "inherits the parent's profile, team and visibility", context do
      assert %{"result" => %{"structuredContent" => created}} =
               tool(
                 "session_create",
                 %{"parent" => context.parent.id, "prompt" => "do the other half"},
                 context
               )

      assert_receive {:pushed, "session.activate", pushed}, 5_000

      sibling = Sessions.get(created["session_id"])
      assert sibling.profile == context.parent.profile
      assert sibling.team_id == context.parent.team_id
      assert sibling.visibility == context.parent.visibility

      # And the log says what started it: one of the seven sources, with the parent
      # named, so a reader six weeks later can put the two sessions together.
      assert pushed["origin"]["kind"] == "agent"
      assert pushed["origin"]["source"] == "agent"
      assert pushed["origin"]["parent"] == context.parent.id
      assert pushed["origin"]["payload_digest"] =~ "sha256:"

      # One filter finds it beside every other unattended start.
      assert {:ok, %{"sessions" => automated}} =
               Harness.call("sessions.list", %{"source" => "agent"}, context.context)

      assert [%{"id" => id}] = automated
      assert id == sibling.id
    end

    test "may run an agent the parent could run", context do
      assert %{"result" => %{"structuredContent" => created}} =
               tool(
                 "session_create",
                 %{
                   "parent" => context.parent.id,
                   "prompt" => "review it",
                   "agent" => "reviewer"
                 },
                 context
               )

      assert_receive {:pushed, "session.activate", pushed}, 5_000
      assert pushed["agent"] == "reviewer"
      assert is_binary(created["session_id"])
    end

    test "may not run one the parent could not, and is told so", context do
      # Narrowed to `build` alone: the team's grant is what the parent's offering comes
      # from, and `reviewer` is outside it.
      {:ok, _} =
        Identity.grant(context.team, "dev", %{
          "entitlements" => [%{kind: "agent", name: "build", mode: "allow"}]
        })

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               tool(
                 "session_create",
                 %{
                   "parent" => context.parent.id,
                   "prompt" => "review it",
                   "agent" => "reviewer"
                 },
                 context
               )

      # A refusal the model can read and act on, naming what it *may* run — not a
      # transport error it can only report.
      assert text =~ "forbidden"
      assert text =~ "reviewer"
      refute_receive {:pushed, "session.activate", _}, 300
    end

    test "cannot be spawned from somebody else's session", context do
      bea = person("bea@example.test", ["engineering"])

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               tool(
                 "session_create",
                 %{"parent" => context.parent.id, "prompt" => "not mine"},
                 %{context | context: %{user: bea, platform_admin?: false}}
               )

      # The parent is private and belongs to ada. Not found rather than forbidden,
      # because whether a session exists is itself something a stranger should not learn.
      assert text =~ "not_found"
    end
  end

  describe "firing a trigger" do
    test "is an `agent` firing, which a caller at /rpc may not claim", context do
      {:ok, principal, _secret} =
        principal!(context.team, %{
          name: "nightly",
          profiles: ["dev"],
          sponsor: context.ada.subject
        })

      {:ok, _trigger} =
        Triggers.put(
          context.team,
          %{
            "name" => "triage",
            "principal" => principal.subject,
            "profile" => "dev",
            "source" => %{"kind" => "manual"},
            "prompt_template" => "do the thing"
          },
          "root@example.test"
        )

      # As the principal, which is the credential a profile's bundle points this server
      # at. A person who administers the team could fire it too, and that is the same
      # method through the same door.
      service = %{context | context: %{user: Principals.user_for(principal), platform_admin?: false}}

      assert %{"result" => %{"structuredContent" => fired}} =
               tool(
                 "trigger_fire",
                 %{"trigger" => "engineering/triage", "idempotency_key" => "from-an-agent"},
                 service
               )

      assert fired["run"]["source"] == "agent"
      assert_receive {:pushed, "session.activate", _}, 5_000

      # And the same claim through the ordinary door is refused. The discriminator is
      # only worth having if the door vouches for it: a caller that could label its own
      # runs `agent` would make "an agent did this" mean nothing.
      assert {:error, error} =
               Harness.call(
                 "trigger.fire",
                 %{
                   "trigger" => "engineering/triage",
                   "idempotency_key" => "from-a-liar",
                   "source" => "agent"
                 },
                 service.context
               )

      assert error.message == "invalid_params"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp create(context, params), do: Harness.call("session.create", params, context.context)

  defp tool(name, arguments, context) do
    call("tools/call", %{"name" => name, "arguments" => arguments}, context)
  end

  defp call(method, params, context) do
    request = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    {:reply, response} =
      MCP.handle(request, Map.put(context.context, :vouched_source, "agent"))

    response
  end

  defp bundle_content do
    %{
      "schema" => 1,
      "agents" => [
        %{"name" => "reviewer", "definition" => "---
mode: primary
---
Review."},
        %{"name" => "helper", "definition" => "You help."}
      ]
    }
  end
end
