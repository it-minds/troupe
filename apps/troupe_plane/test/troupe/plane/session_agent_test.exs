defmodule Troupe.Plane.SessionAgentTest do
  @moduledoc """
  A session runs as an agent its profile offers (#882). A create that names none is given
  the profile's default by the plane, kept on the row, rather than left to the pod, whose
  own default is `build` whatever the profile offers; a create naming one the profile does
  not have, or on a profile that offers none, is refused before anything is spent; every
  activation, a wake included, sends the agent on the row; and a pod that will not run the
  session as its agent parks it with why, rather than being asked again every tick or at
  every message.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Bundles, FakePod, Fleet, Harness, Repo, Sessions}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Sessions.Session

  @moduletag timeout: 60_000

  @refused %{
    "code" => -32_602,
    "message" => "invalid_params",
    "data" => %{"reason" => "agent_not_here", "agent" => "build"}
  }

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
    ada = person("ada@example.test", ["engineering"])
    {:ok, _bundle} = Bundles.publish("stable", bundle_content(), announce: false)

    %{port: Listener.port(), team: team, ada: ada}
  end

  describe "a create" do
    test "that names no agent runs as the profile's own when it does not offer build",
         context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      profile(%{"allow" => ["pr-reviewer"]})

      assert {:ok, created} = create(context.ada)
      assert_receive {:pushed, "session.activate", pushed}, 5_000
      assert pushed["agent"] == "pr-reviewer"
      assert Sessions.get(created["session_id"]).agent == "pr-reviewer"
    end

    test "that names no agent runs as build where the profile offers it, as it always did",
         context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      profile(nil)

      assert {:ok, created} = create(context.ada)
      assert_receive {:pushed, "session.activate", pushed}, 5_000
      assert pushed["agent"] == "build"
      assert Sessions.get(created["session_id"]).agent == "build"
    end

    test "naming an agent the profile does not have is refused, naming it and those there are",
         context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      profile(%{"allow" => ["pr-reviewer"]})

      assert {:error, error} = create(context.ada, "build")
      assert error.message == "invalid_params"
      assert error.data.field == "agent"
      assert error.data.agent == "build"
      assert error.data.agents == ["pr-reviewer"]
      refute_received {:pushed, "session.activate", _}
    end

    test "on a profile that offers no agent a session can start as is refused", context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      # A subagent alone: nothing a session runs as.
      profile(%{"allow" => ["helper"]})

      assert {:error, error} = create(context.ada)
      assert error.message == "invalid_params"
      assert error.data.field == "agent"
      assert error.data.agents == []
      assert error.data.reason =~ "dev offers no agent"
      refute_received {:pushed, "session.activate", _}
    end

    test "the pod refuses for its agent answers that, and keeps no row", context do
      FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0",
        refuse: %{"session.activate" => @refused}
      )

      profile(nil)

      assert {:error, error} = create(context.ada)
      assert error.message == "invalid_params"
      assert error.data.agent == "build"
      assert error.data.reason =~ "build is not an agent on dev"
      assert Repo.aggregate(Session, :count) == 0
    end
  end

  describe "a wake" do
    test "sends the agent the session ran as", context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      profile(%{"allow" => ["pr-reviewer"]})
      session = session!(context, state: "dormant", agent: "pr-reviewer")

      assert {:ok, _opened} = open(session, context.ada)
      assert_receive {:pushed, "session.activate", pushed}, 5_000
      assert pushed["agent"] == "pr-reviewer"
    end

    test "of a row with no agent sends the profile's default, never build it lacks",
         context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      profile(%{"allow" => ["pr-reviewer"]})
      session = session!(context, state: "dormant", agent: nil)

      assert {:ok, _opened} = open(session, context.ada)
      assert_receive {:pushed, "session.activate", pushed}, 5_000
      assert pushed["agent"] == "pr-reviewer"
    end

    test "the pod refuses for its agent parks the session with why, and is not tried again",
         context do
      FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0",
        refuse: %{"session.activate" => @refused}
      )

      profile(nil)
      session = session!(context, state: "dormant", agent: "build")

      assert {:error, error} = open(session, context.ada)
      assert error.message == "forbidden"
      assert error.data.agent == "build"
      assert error.data.reason =~ "build is not an agent on dev"
      assert_receive {:pushed, "session.activate", _}, 5_000

      parked = Sessions.get(session.id)
      assert parked.state == "read_only"
      assert parked.failed_reason == "agent_not_here"
      epoch = parked.epoch

      # The next open is refused before any pod is asked, and the epoch stays where it is.
      assert {:error, %{message: "forbidden"}} = open(session, context.ada)
      refute_receive {:pushed, "session.activate", _}, 200
      assert Sessions.get(session.id).epoch == epoch
    end
  end

  describe "a session that waited" do
    test "and is refused its agent is parked with why, not queued again, and its client told",
         context do
      FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0",
        refuse: %{"session.activate" => @refused}
      )

      profile(nil)
      session = session!(context, state: "pending", agent: "build")

      assert {:error, error} = Harness.admit(Sessions.get(session.id))
      assert error.message == "forbidden"
      assert_receive {:pushed, "session.activate", _}, 5_000

      parked = Sessions.get(session.id)
      assert parked.state == "read_only"
      assert parked.failed_reason == "agent_not_here"
      assert Sessions.pending_for("dev") == []

      # The client still asking after it hears why, not "pending" for ever.
      assert {:error, minted} =
               Harness.call("token.mint", %{"session_id" => session.id}, as(context.ada))

      assert minted.message == "forbidden"
      assert minted.data.reason =~ "build is not an agent on dev"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp as(user), do: %{user: user, platform_admin?: false}

  defp create(user, agent \\ nil) do
    params = %{"profile" => "dev", "team" => "engineering"}
    params = if agent, do: Map.put(params, "agent", agent), else: params
    Harness.call("session.create", params, as(user))
  end

  defp open(session, user) do
    Harness.call("session.open", %{"session_id" => session.id, "mode" => "activate"}, as(user))
  end

  defp session!(context, opts) do
    {:ok, session} =
      Sessions.create(%{
        id: "s-agent-#{System.unique_integer([:positive])}",
        owner_id: context.ada.id,
        owner_subject: context.ada.subject,
        team_id: context.team.id,
        profile: "dev",
        visibility: "team",
        state: Keyword.fetch!(opts, :state),
        agent: Keyword.get(opts, :agent),
        epoch: 1
      })

    session
  end

  defp profile(rule) do
    spec = if rule, do: %{"agents" => rule}, else: %{}

    {:ok, _profile} =
      Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable", replicas: 1, spec: spec})

    :ok
  end

  defp bundle_content do
    %{
      "schema" => 1,
      "agents" => [
        %{
          "name" => "pr-reviewer",
          "definition" => "---\nmode: primary\ntools: [read_file, delegate]\n---\nReview."
        },
        %{"name" => "helper", "definition" => "---\nmode: subagent\n---\nYou help."}
      ],
      "skills" => [],
      "mcp_servers" => []
    }
  end
end
