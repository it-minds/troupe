defmodule Troupe.Session.ClientToolsTest do
  @moduledoc """
  The consent gate and the ownership rule, tested where they live.

  The gateway's tests prove the whole path through the protocol; this proves the
  properties themselves, including the ones a protocol test cannot reach cheaply — a
  challenge going stale, a registrant dying, a client's tool going through the same
  allowlist as `shell`.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.Definition
  alias Troupe.Protocol.Event
  alias Troupe.Session.{ClientTools, Log, Summary}
  alias Troupe.Tool
  alias Troupe.Tool.Ctx
  alias Troupe.Tools

  setup context do
    session = start_session(context, default: {:text, "ok"})
    Map.merge(context, session)
  end

  defp spec(name \\ "notes.search", run \\ fn _args, _ctx -> {:ok, "served"} end) do
    %{name: name, description: "Search my local notes.", schema: %{"type" => "object"}, run: run}
  end

  defp consent!(session_id, connection, subject, names) do
    {:ok, challenge} = ClientTools.challenge(session_id, connection, subject, names)
    %{"challenge" => challenge["challenge"], "confirmed_by" => subject}
  end

  describe "consent" do
    test "no challenge, no registration", %{session: session} do
      assert {:error, :consent_required} =
               ClientTools.register(session.id, self(), %{}, specs: [spec()], subject: "ada")

      assert ClientTools.list(session.id) == []
    end

    test "a challenge is spent once", %{session: session} do
      consent = consent!(session.id, self(), "ada", ["notes.search"])

      assert {:ok, ["client.notes.search"]} =
               ClientTools.register(session.id, self(), consent, specs: [spec()], subject: "ada")

      # Replaying the same consent is not a second consent. Deliberately not treated as
      # an idempotent no-op: a replayed challenge is the one thing a stolen challenge
      # would look like.
      assert {:error, :consent_required} =
               ClientTools.register(session.id, self(), consent, specs: [spec()], subject: "ada")
    end

    test "a challenge belongs to the connection it was issued to", %{session: session} do
      other = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(other, :kill) end)

      consent = consent!(session.id, other, "ada", ["notes.search"])

      assert {:error, :consent_belongs_to_another_client} =
               ClientTools.register(session.id, self(), consent, specs: [spec()], subject: "ada")
    end

    test "a challenge belongs to the subject it was issued to", %{session: session} do
      consent = consent!(session.id, self(), "ada", ["notes.search"])

      assert {:error, :consent_belongs_to_another_client} =
               ClientTools.register(session.id, self(), consent, specs: [spec()], subject: "bob")
    end

    test "a challenge covers exactly the tools it named", %{session: session} do
      consent = consent!(session.id, self(), "ada", ["notes.search"])

      assert {:error, :consent_covers_other_tools} =
               ClientTools.register(session.id, self(), consent,
                 specs: [spec(), spec("mail.send")],
                 subject: "ada"
               )
    end

    test "the challenge says what to show and which tools it is about", %{session: session} do
      {:ok, challenge} = ClientTools.challenge(session.id, self(), "ada", ["notes.search"])

      assert challenge["prompt"] =~ "notes.search"
      assert challenge["prompt"] =~ "your machine"
      assert challenge["tools"] == ["notes.search"]
      assert byte_size(challenge["challenge"]) >= 32
    end
  end

  describe "registration" do
    test "taints the session, durably, and says who did it", %{session: session} do
      actor = Event.Actor.user("ada@example.test", "Ada")
      consent = consent!(session.id, self(), "ada@example.test", ["notes.search"])

      {:ok, _} =
        ClientTools.register(session.id, self(), consent,
          specs: [spec()],
          subject: "ada@example.test",
          actor: actor
        )

      events = Log.replay(session.id)

      assert registered = Enum.find(events, &(&1.type == "tools_registered"))
      assert registered.data["tools"] == ["client.notes.search"]
      assert registered.data["consent"]["confirmed_by"] == "ada@example.test"

      assert tainted = Enum.find(events, &(&1.type == "session_tainted"))
      assert tainted.data["kind"] == "personal_connector"
      assert tainted.data["actor"] == "ada@example.test"
      assert tainted.data["tools"] == ["client.notes.search"]

      assert [%{"kind" => "personal_connector"}] = ClientTools.taint(session.id)
    end

    test "the taint reaches the summary projection", %{session: session} do
      consent = consent!(session.id, self(), "ada", ["notes.search"])
      {:ok, _} = ClientTools.register(session.id, self(), consent, specs: [spec()], subject: "ada")

      snapshot = await_taint(session.id)
      assert [%{"kind" => "personal_connector", "tools" => ["client.notes.search"]}] = snapshot
    end

    test "an untainted session's summary has no taint key at all", %{session: session} do
      # The projection gains the key only when the thing it describes has happened, so
      # every log written before this existed folds to exactly what it folded to before.
      refute Map.has_key?(Summary.snapshot(session.id), "taint")
    end
  end

  describe "the tool itself" do
    setup %{session: session} do
      consent = consent!(session.id, self(), "ada", ["notes.search"])

      {:ok, _} =
        ClientTools.register(session.id, self(), consent,
          specs: [spec("notes.search", fn args, _ctx -> {:ok, "served #{args["q"]}"} end)],
          subject: "ada"
        )

      :ok
    end

    test "is prefixed, so it cannot shadow a built-in", %{session: session} do
      names = session.id |> Tools.all() |> Enum.map(&Tool.name/1)

      assert "client.notes.search" in names
      assert "shell" in names
    end

    test "belongs to one session and not to the pod", %{session: session} do
      refute "client.notes.search" in Enum.map(Tools.all(), &Tool.name/1)
      assert {:error, {:unknown_tool, _}} = Tools.fetch("client.notes.search")
      assert {:ok, _} = Tools.fetch("client.notes.search", session.id)
    end

    test "asks by default, because consent was to offering it and not to every call",
         %{session: session} do
      {:ok, tool} = Tools.fetch("client.notes.search", session.id)
      assert Tool.default_permission(tool) == :ask
      assert Tool.mode(tool) == :task
    end

    test "goes through the same allowlist as a built-in", %{session: session} do
      narrow = %Definition{name: "narrow", mode: :primary, prompt: "", tools: ["read_file"]}
      ctx = ctx(session.id)

      assert {:reject, rejected} = Tools.authorize("client.notes.search", narrow, ctx)
      assert rejected.content =~ "not available"

      open = %Definition{name: "open", mode: :primary, prompt: "", tools: :all}
      assert {:run, tool, :task} = Tools.authorize("client.notes.search", open, ctx)
      assert Tool.name(tool) == "client.notes.search"
    end

    test "a dropped registrant takes its tools with it, and says so", %{session: session} do
      registrant =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      consent = consent!(session.id, registrant, "bob", ["mail.send"])
      {:ok, _} = ClientTools.register(session.id, registrant, consent, specs: [spec("mail.send")], subject: "bob")

      assert {:ok, ^registrant} = ClientTools.owner(session.id, "client.mail.send")

      send(registrant, :stop)

      assert eventually(fn -> ClientTools.owner(session.id, "client.mail.send") == :error end)

      unregistered =
        session.id
        |> Log.replay()
        |> Enum.filter(&(&1.type == "tools_unregistered"))

      assert Enum.any?(unregistered, &(&1.data["tools"] == ["client.mail.send"]))
      assert Enum.any?(unregistered, &(&1.data["reason"] == "disconnected"))

      # And the tool this test's own connection registered is untouched: a disconnect
      # takes one registrant's tools, not every client's.
      assert {:ok, _} = ClientTools.owner(session.id, "client.notes.search")
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp ctx(session_id) do
    %Ctx{
      session_id: session_id,
      agent_path: ["root"],
      workspace: nil,
      call_id: "call-1",
      agent_pid: self()
    }
  end

  defp await_taint(session_id) do
    eventually(fn -> Map.get(Summary.snapshot(session_id), "taint") end)
  end

  defp eventually(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("condition never held")
        else
          Process.sleep(20)
          poll(fun, deadline)
        end

      truthy ->
        truthy
    end
  end
end
