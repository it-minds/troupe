defmodule Troupe.Plane.MemoryProposalsTest do
  @moduledoc """
  What an agent may write back above its person's own memory (#55): a proposal for its
  team's memory or the organisation's, kept for review and in no document until an
  administrator who may change that level accepts it, which writes it as an entry with the
  session and agent as its provenance, or declines it with a sentence the session is told.
  The setting `memory_proposals` switches them off, refused in words. And a profile's
  `extends` changing reaches its running sessions at their next turn, as a save does.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Audit, FakePod, Fleet, Harness, Identity, Memory, Sessions, Settings}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Memory.{Proposal, Proposals}

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    {:ok, _} = Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable", replicas: 1})
    engineering = team_with_grant("engineering", "dev", name: "engineering")
    design = team_with_grant("design", "dev", name: "design")
    root = person("root@example.test", ["platform"])
    lead = person("lead@example.test", ["engineering"])
    {:ok, _} = Identity.add_team_admin(engineering, lead.subject, root.subject)
    ada = person("ada@example.test", ["engineering"])

    %{
      port: Listener.port(),
      root: Admin.actor_for(root),
      lead: Admin.actor_for(lead),
      ada: ada,
      engineering: engineering,
      design: design
    }
  end

  describe "a pod's session proposes" do
    test "for its own team: kept for review, in no document, audited without the entry", context do
      worker = enrolled(context.port, "dev-token", "troupe-w-dev-0")
      answer_index(worker, [])
      [pod] = Fleet.list_workers("dev")
      session(context.ada, "s-prop", pod, context.engineering)

      assert {:ok, proposal} =
               call(worker, "session.memory.propose", %{
                 "session_id" => "s-prop",
                 "scope" => "team",
                 "append" => "  Releases go out on Tuesdays. ",
                 "topic" => "Releases",
                 "agent" => "build"
               })

      assert %{"scope" => "team", "team" => "engineering", "state" => "pending", "entry" => "Releases go out on Tuesdays."} = proposal
      assert proposal["topic"] == "Releases"
      assert proposal["by"] == "ada@example.test"
      assert proposal["message"] =~ "awaiting review"

      # In no document: no session reads a proposal.
      assert Memory.current(context.engineering) == nil

      [row] = Enum.filter(Audit.list(), &(&1.action == "memory.propose"))
      assert row.actor == "ada@example.test"
      assert row.subject_id == "team/engineering"
      assert row.detail["session"] == "s-prop"
      refute inspect(row.detail) =~ "Tuesdays"

      # And the organisation's, the same way.
      assert {:ok, %{"scope" => "organisation", "team" => nil}} =
               call(worker, "session.memory.propose", %{"session_id" => "s-prop", "scope" => "organisation", "append" => "Be kind."})
    end

    test "is refused for a profile's, for a session it does not hold, and for no team", context do
      worker = enrolled(context.port, "dev-token", "troupe-w-dev-0")
      answer_index(worker, [])
      [pod] = Fleet.list_workers("dev")
      session(context.ada, "s-noteam", pod, nil)

      assert {:error, %{"message" => "invalid_params", "data" => %{"reason" => reason}}} =
               call(worker, "session.memory.propose", %{"session_id" => "s-noteam", "scope" => "team", "append" => "x"})

      assert reason =~ "runs in no team"

      assert {:error, %{"message" => "invalid_params"}} =
               call(worker, "session.memory.propose", %{"session_id" => "s-noteam", "scope" => "profile", "append" => "x"})

      assert {:error, %{"message" => "not_found"}} =
               call(worker, "session.memory.propose", %{"session_id" => "s-elsewhere", "scope" => "organisation", "append" => "x"})

      assert Repo.aggregate(Proposal, :count) == 0
    end

    test "is refused in words while the setting switches proposals off", context do
      worker = enrolled(context.port, "dev-token", "troupe-w-dev-0")
      answer_index(worker, [])
      [pod] = Fleet.list_workers("dev")
      session(context.ada, "s-off", pod, context.engineering)

      assert %{label: "Agents may propose memory", unit: :switch} = Settings.definition("memory_proposals")
      {:ok, _} = Settings.put("memory_proposals", false, "root@example.test")

      assert {:error, %{"message" => "forbidden", "data" => %{"reason" => reason}}} =
               call(worker, "session.memory.propose", %{"session_id" => "s-off", "scope" => "team", "append" => "x"})

      assert reason =~ "switched off"
      assert reason =~ "memory_proposals"
      assert Repo.aggregate(Proposal, :count) == 0
      assert {:ok, %{enabled: false, proposals: []}} = Admin.memory_proposals(context.root)
    end
  end

  describe "a person's machine proposes through me.memory.propose" do
    test "for their only team, or the one named; their own answer carries it", context do
      user = %{user: context.ada, platform_admin?: false}

      assert {:ok, %{"team" => "engineering", "where" => "machine", "session_id" => "laptop-1"}} =
               Harness.call("me.memory.propose", %{"scope" => "team", "append" => "Use the staging cluster.", "session" => "laptop-1", "agent" => "build"}, user)

      assert {:ok, %{"proposals" => [%{"state" => "pending", "team" => "engineering"}]}} =
               Harness.call("me.memory", %{}, user) |> signed_body()

      # In two teams, the refusal names them.
      bo = person("bo@example.test", ["engineering", "design"])

      assert {:error, %{data: %{reason: reason}}} =
               Harness.call("me.memory.propose", %{"scope" => "team", "append" => "x"}, %{user: bo, platform_admin?: false})

      assert reason =~ "design, engineering"

      assert {:ok, %{"team" => "design"}} =
               Harness.call("me.memory.propose", %{"scope" => "team", "team" => "design", "append" => "x"}, %{user: bo, platform_admin?: false})

      assert {:error, %{data: %{reason: "you are not in a team called lab"}}} =
               Harness.call("me.memory.propose", %{"scope" => "team", "team" => "lab", "append" => "x"}, %{user: bo, platform_admin?: false})
    end
  end

  describe "an administrator decides" do
    test "the queue is each admin's: a team admin sees their team's, a platform admin every one", context do
      {:ok, team} = Proposals.propose(context.ada, "team", context.engineering, "Tabs.", topic: "Style")
      {:ok, _} = Proposals.propose(context.ada, "team", context.design, "Grids.", topic: "Style")
      {:ok, org} = Proposals.propose(context.ada, "organisation", nil, "Be kind.", [])

      assert {:ok, %{enabled: true, proposals: mine}} = Admin.memory_proposals(context.lead)
      assert Enum.map(mine, & &1["id"]) == [team.id]

      assert {:ok, %{proposals: every}} = Admin.memory_proposals(context.root)
      assert length(every) == 3

      # Another team's is not there for the team admin; the organisation's is not theirs.
      [design] = Enum.filter(every, &(&1["team"] == "design"))
      assert {:error, %{message: "not_found"}} = Admin.memory_accept(context.lead, design["id"])
      assert {:error, %{message: "forbidden"}} = Admin.memory_accept(context.lead, org.id)
      assert {:error, %{message: "forbidden"}} = Admin.memory_proposals(Admin.actor_for(context.ada))
    end

    test "accepting writes the entry with its provenance, audits it and tells the pod's session", context do
      worker = enrolled(context.port, "dev-token", "troupe-w-dev-0")
      answer_index(worker, [])
      [pod] = Fleet.list_workers("dev")
      session(context.ada, "s-acc", pod, context.engineering)
      {:ok, _} = Memory.put(context.engineering, "## Releases\n\n- From main.", "lead@example.test", 0)

      {:ok, %{"id" => id}} =
        call(worker, "session.memory.propose", %{
          "session_id" => "s-acc",
          "scope" => "team",
          "append" => "Releases go out on Tuesdays.",
          "topic" => "releases",
          "agent" => "build"
        })

      assert {:ok, %{"state" => "accepted", "version" => 2, "decided_by" => "lead@example.test"} = accepted} =
               Admin.memory_accept(context.lead, id)

      assert Memory.current(context.engineering).text == "## Releases\n\n- From main.\n- Releases go out on Tuesdays."

      # Who wrote the line: the agent of the session it came from, saved by the admin.
      assert %{"session" => "s-acc", "agent" => "build", "by" => "lead@example.test", "version" => 2} =
               List.last(Memory.blame(context.engineering))

      actions = Enum.map(Audit.list(), & &1.action)
      assert "memory.proposal.accept" in actions
      assert "memory.put" in actions

      # The session is told in a line: the save's push, then the decision's.
      assert %{"params" => %{"session_id" => "s-acc"}} = push(worker, "session.memory")
      assert %{"params" => %{"proposal" => ^id, "state" => "accepted", "message" => message}} = push(worker, "memory.proposal.decided")
      assert message == accepted["message"]
      assert message =~ "accepted by lead@example.test"
      assert message =~ "version 2"

      # Decided once.
      assert {:error, %{message: "conflict", data: %{reason: reason}}} = Admin.memory_decline(context.root, id, "No.")
      assert reason =~ "accepted by lead@example.test"
    end

    test "declining writes nothing, needs a reason, and the session hears it", context do
      worker = enrolled(context.port, "dev-token", "troupe-w-dev-0")
      answer_index(worker, [])
      [pod] = Fleet.list_workers("dev")
      session(context.ada, "s-dec", pod, context.engineering)

      {:ok, %{"id" => id}} =
        call(worker, "session.memory.propose", %{"session_id" => "s-dec", "scope" => "organisation", "append" => "Deploy on Fridays."})

      assert {:error, %{message: "invalid_params"}} = Admin.memory_decline(context.root, id, "  ")

      assert {:ok, %{"state" => "declined", "reason" => "We never deploy on Fridays."}} =
               Admin.memory_decline(context.root, id, "We never deploy on Fridays.")

      assert Memory.current(:organisation) == nil
      assert %{"params" => %{"message" => message}} = push(worker, "memory.proposal.decided")
      assert message =~ "declined by root@example.test: We never deploy on Fridays."

      [row] = Enum.filter(Audit.list(), &(&1.action == "memory.proposal.decline"))
      assert row.subject_id == "organisation"
      assert row.detail["reason"] == "We never deploy on Fridays."

      # The person's own answer says it, this week.
      assert [%{"state" => "declined"}] = Proposals.own(context.ada)
    end

    test "an erased session's proposals that were not accepted go with it", context do
      {:ok, pending} = Proposals.propose(context.ada, "organisation", nil, "Secret.", session: "s-gone")
      {:ok, kept} = Proposals.propose(context.ada, "organisation", nil, "Public.", session: "s-gone")
      {:ok, _} = Proposals.accept(kept, "root@example.test")

      assert :ok = Proposals.forget_session("s-gone")
      assert Proposals.get(pending.id) == nil
      assert %Proposal{state: "accepted", session_id: nil} = Proposals.get(kept.id)
    end

    test "a person has at most twenty waiting", context do
      for n <- 1..20, do: {:ok, _} = Proposals.propose(context.ada, "organisation", nil, "Entry #{n}.", [])
      assert {:error, reason} = Proposals.propose(context.ada, "organisation", nil, "One more.", [])
      assert reason =~ "waiting for review already"
    end
  end

  describe "a profile's extends" do
    test "changing it reaches the running sessions at their next turn, chain and all", context do
      worker = enrolled(context.port, "dev-token", "troupe-w-dev-0")
      answer_index(worker, [])
      [pod] = Fleet.list_workers("dev")
      {:ok, _} = Fleet.put_profile(%{name: "base", config_bundle_channel: "stable", replicas: 0})
      {:ok, _} = Memory.put("base", "## Base\n\nFrom the base.", "root@example.test", 0)
      {:ok, %{now: own}} = Memory.put("dev", "## Dev\n\nFrom dev.", "root@example.test", 0)
      session(context.ada, "s-chain", pod, context.engineering)

      read = [%{"scope" => "profile", "name" => "dev", "version" => own.version, "hash" => own.hash}]

      assert {:ok, %{"current" => true}} =
               call(worker, "session.memory.read", %{"session_id" => "s-chain", "documents" => read})

      # dev comes to extend base: the session is told at once, and its next turn is behind.
      {:ok, _} = Fleet.put_profile(%{name: "dev", extends: "base"})
      assert %{"params" => %{"session_id" => "s-chain", "memory" => memory}} = push(worker, "session.memory")
      assert [%{"name" => "base", "chain" => ["base", "dev"]}, %{"name" => "dev", "chain" => ["base", "dev"]}] = memory

      assert {:ok, %{"current" => false, "memory" => [_base, _dev]}} =
               call(worker, "session.memory.read", %{"session_id" => "s-chain", "documents" => read})
    end
  end

  defp session(user, id, pod, team) do
    {:ok, _} =
      Sessions.create(%{id: id, owner_subject: user.subject, owner_id: user.id, profile: "dev", team_id: team && team.id})

    {:ok, _} = Sessions.place(id, pod)
  end

  defp signed_body({:ok, answer}), do: {:ok, Map.delete(answer, "signed")}

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
    %{socket: socket, id: :counters.new(1, [])}
  end

  defp enrolled(port, token, pod_name) do
    worker = connect(port)

    {:ok, _} =
      call(worker, "enrol", %{
        "token" => FakePod.token(token),
        "pod_name" => pod_name,
        "capacity" => 4,
        "disk_total_bytes" => 1000
      })

    worker
  end

  defp answer_index(worker, sessions, attempts \\ 8)
  defp answer_index(_worker, _sessions, 0), do: flunk("no session.index request arrived")

  defp answer_index(worker, sessions, attempts) do
    case read(worker) do
      %{"method" => "session.index", "id" => id} ->
        :ok =
          :gen_tcp.send(worker.socket, [
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"sessions" => sessions}}),
            "\n"
          ])

      _other ->
        answer_index(worker, sessions, attempts - 1)
    end
  end

  defp call(worker, method, params) do
    :counters.add(worker.id, 1, 1)
    id = :counters.get(worker.id, 1)

    :ok =
      :gen_tcp.send(worker.socket, [
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}),
        "\n"
      ])

    case answer(worker, id) do
      %{"result" => result} -> {:ok, result}
      %{"error" => error} -> {:error, error}
      other -> {:error, other}
    end
  end

  defp push(worker, method, attempts \\ 5)
  defp push(_worker, method, 0), do: flunk("no #{method} push arrived")

  defp push(worker, method, attempts) do
    case read(worker) do
      %{"method" => ^method} = message -> message
      _other -> push(worker, method, attempts - 1)
    end
  end

  defp answer(worker, id) do
    case read(worker) do
      %{"method" => _method} -> answer(worker, id)
      %{"id" => ^id} = message -> message
      other -> other
    end
  end

  defp read(worker, timeout \\ 5_000) do
    {:ok, line} = :gen_tcp.recv(worker.socket, 0, timeout)
    line |> String.split("\n", trim: true) |> hd() |> Jason.decode!()
  end
end
