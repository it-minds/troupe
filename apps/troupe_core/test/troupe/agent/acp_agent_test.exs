defmodule Troupe.Agent.ACPAgentTest do
  @moduledoc """
  A third-party ACP agent, served through the mount table rather than the disk.

  This is the claim that makes running somebody else's agent inside a session defensible,
  and it is a narrow one: **the refusal an ACP agent gets is the refusal a tool gets**.
  Not a check written in the ACP layer that happens to agree with the tool layer — the same
  `Mounts.resolve/3`, so the two cannot drift apart and a mount added later applies without
  anybody remembering to apply it here.

  The tests are therefore mostly about paths: which ones resolve, which ones do not, and
  whether a read-only mount is read-only to a subprocess as well as to a model.
  """

  use ExUnit.Case, async: true

  alias Troupe.Agent.ACPAgent
  alias Troupe.{Mounts, Workspace}

  # Above the longest wait a test here declares (30 s for a result, then 5 and 3 more), so a
  # subprocess that is slow fails the assertion that waited for it, not the test's clock.
  @moduletag timeout: 60_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-acp-#{System.unique_integer([:positive])}")
    session_root = Path.join(base, "session")
    org = Path.join(base, "org")
    outside = Path.join(base, "outside")

    for dir <- [session_root, org, outside], do: File.mkdir_p!(dir)
    File.write!(Path.join(session_root, "notes.md"), "one\ntwo\nthree\nfour\n")
    File.write!(Path.join(org, "handbook.md"), "how we work")
    File.write!(Path.join(outside, "secret.txt"), "not yours")

    on_exit(fn -> File.rm_rf!(base) end)

    mounts =
      Mounts.new([
        %{name: "session", kind: :session, root: session_root, mode: :rw},
        # Read-only on purpose: the interesting question is not whether an agent can be kept
        # out, but whether a mount it *can* see keeps its mode.
        %{name: "org", kind: :org, root: org, mode: :ro}
      ])

    workspace = %{Workspace.new!(session_root) | mounts: mounts}

    %{workspace: workspace, base: base, session_root: session_root, outside: outside}
  end

  # A real subprocess that speaks enough ACP to be a delegate. Elixir rather than a shell
  # script or Python: it is the one interpreter every machine that runs this suite has, and
  # a fake agent that cannot start is a test about the fixture. It speaks JSON through the
  # standard library's `JSON`, so it needs nothing on its code path.
  #
  # It takes the path to ask for as its argument, which is how one script covers both the
  # path that resolves and the path that does not.
  defp fake_agent(base) do
    path = Path.join(base, "fake-acp-agent.exs")

    File.write!(path, """
    defmodule FakeACPAgent do
      def run([asking_for]) do
        loop(asking_for)
      end

      defp loop(asking_for) do
        case IO.read(:stdio, :line) do
          :eof ->
            :ok

          line ->
            line |> String.trim() |> handle(asking_for)
            loop(asking_for)
        end
      end

      defp handle("", _asking_for), do: :ok

      defp handle(line, asking_for) do
        case JSON.decode(line) do
          {:ok, %{"method" => "initialize", "id" => id}} ->
            send_json(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"protocolVersion" => 1}})

          {:ok, %{"method" => "session/new", "id" => id}} ->
            send_json(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"sessionId" => "acp-1"}})

          {:ok, %{"method" => "session/prompt", "id" => id}} ->
            prompt(id, asking_for)

          _other ->
            :ok
        end
      end

      # Everything this agent can see, it sees through its client.
      defp prompt(id, asking_for) do
        send_json(%{
          "jsonrpc" => "2.0",
          "id" => 900,
          "method" => "fs/read_text_file",
          "params" => %{"path" => asking_for}
        })

        answer = IO.read(:stdio, :line) |> String.trim() |> JSON.decode!()

        text =
          case answer do
            %{"result" => %{"content" => content}} ->
              "read: " <> (content |> String.split("\\n") |> List.first())

            %{"error" => %{"message" => message}} ->
              "refused: " <> message
          end

        send_json(%{
          "jsonrpc" => "2.0",
          "method" => "session/update",
          "params" => %{
            "sessionId" => "acp-1",
            "update" => %{
              "sessionUpdate" => "agent_message_chunk",
              "content" => %{"type" => "text", "text" => text}
            }
          }
        })

        send_json(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"stopReason" => "end_turn"}})
      end

      defp send_json(message) do
        IO.puts(JSON.encode!(message))
      end
    end

    FakeACPAgent.run(System.argv())
    """)

    path
  end

  defp acp_entry(base, asking_for) do
    %{
      name: "gemini",
      command: System.find_executable("elixir"),
      # A bare `elixir` and no `-pa`. Each `-pa` directory is looked in first for every
      # module the script's compile loads, and with one for each of the build's fifty-odd
      # apps the subprocess took seconds to start instead of half of one, and over twenty
      # on a loaded machine, where "a subprocess that exits" ran out of time.
      args: [fake_agent(base), asking_for],
      hash: nil
    }
  end

  defp delegate_to(context, asking_for) do
    {:ok, _pid} =
      ACPAgent.start_link(
        session_id: "s-acp",
        agent_path: ["root", "gemini#1"],
        workspace: context.workspace,
        entry: acp_entry(context.base, asking_for),
        task: "have a look",
        parent: self(),
        parent_ref: make_ref()
      )

    :ok
  end

  describe "reading" do
    test "resolves through the mounts, like every other path in a session", context do
      assert {:ok, %{"content" => content}} =
               ACPAgent.serve("fs/read_text_file", %{"path" => "notes.md"}, context.workspace)

      assert content =~ "one"

      # And a named mount is reached by its name, which is the only way anything reaches one.
      assert {:ok, %{"content" => "how we work"}} =
               ACPAgent.serve(
                 "fs/read_text_file",
                 %{"path" => "org:handbook.md"},
                 context.workspace
               )
    end

    test "takes the window ACP asked for", context do
      assert {:ok, %{"content" => content}} =
               ACPAgent.serve(
                 "fs/read_text_file",
                 %{"path" => "notes.md", "line" => 2, "limit" => 2},
                 context.workspace
               )

      assert content == "two\nthree"
    end

    test "a path outside the mounts fails the way any other tool call does", context do
      # Done item 2. Not a check written here: `Workspace.resolve/3` refused it, which is
      # the same call `write_file` and `read_file` make.
      assert {:error, error} =
               ACPAgent.serve(
                 "fs/read_text_file",
                 %{"path" => Path.join(context.outside, "secret.txt")},
                 context.workspace
               )

      assert error["message"] =~ "not in this session's mounts"
      assert error["data"]["path"] =~ "secret.txt"
    end

    test "and so does climbing out of one", context do
      assert {:error, error} =
               ACPAgent.serve(
                 "fs/read_text_file",
                 %{"path" => "../outside/secret.txt"},
                 context.workspace
               )

      assert error["message"] =~ "not in this session's mounts"
    end
  end

  describe "writing" do
    test "lands inside the session's own root", context do
      assert {:ok, %{}} =
               ACPAgent.serve(
                 "fs/write_text_file",
                 %{"path" => "written.txt", "content" => "by the agent"},
                 context.workspace
               )

      assert File.read!(Path.join(context.session_root, "written.txt")) == "by the agent"
    end

    test "is refused by a read-only mount, and the refusal names it", context do
      assert {:error, error} =
               ACPAgent.serve(
                 "fs/write_text_file",
                 %{"path" => "org:handbook.md", "content" => "rewritten"},
                 context.workspace
               )

      # Named, because an agent told *read-only* can choose somewhere else where one told
      # *denied* can only retry. And the mode came from the mount table rather than from a
      # rule this module keeps in step with it.
      assert error["message"] =~ "read-only"
      assert error["data"]["mount"] == "org"
      assert File.read!(Path.join(context.base, "org/handbook.md")) == "how we work"
    end

    test "cannot reach outside the mounts at all", context do
      assert {:error, error} =
               ACPAgent.serve(
                 "fs/write_text_file",
                 %{"path" => Path.join(context.outside, "planted.txt"), "content" => "x"},
                 context.workspace
               )

      assert error["message"] =~ "not in this session's mounts"
      refute File.exists?(Path.join(context.outside, "planted.txt"))
    end
  end

  describe "the terminal" do
    test "is refused, and says why rather than reporting a missing capability", context do
      # A session's shell is approved, budgeted and logged. Handing an ACP agent an
      # unmediated one would be a way round all three, so it is not offered — and the
      # handshake says so, which is the difference between a refusal and a surprise.
      assert ACPAgent.client_capabilities()["terminal"] == false

      assert {:error, error} =
               ACPAgent.serve(
                 "terminal/create",
                 %{"command" => "curl", "args" => ["https://example.com"]},
                 context.workspace
               )

      assert error["data"]["reason"] =~ "approved, budgeted and logged"
    end
  end

  describe "a real subprocess" do
    test "does the handshake, takes the task, and reads through the client", context do
      :ok = delegate_to(context, "notes.md")

      assert_receive {:child_result, _ref, {:ok, summary, _usage}}, 30_000

      # It asked its client for a file and got the session's, not the pod's. The whole
      # exchange \u2014 initialize, session/new, session/prompt, fs/read_text_file \u2014 happened
      # over a pipe with a program that knows nothing about Troupe.
      assert summary =~ "read: one"
    end

    test "and a path outside the mounts is refused, in ACP's own envelope", context do
      :ok = delegate_to(context, Path.join(context.outside, "secret.txt"))

      assert_receive {:child_result, _ref, {:ok, summary, _usage}}, 30_000

      # Done item 2, end to end: the refusal came back as an ACP error the agent could read
      # and act on, and it is the one `Workspace.resolve/3` gives every tool.
      assert summary =~ "refused: that path is not in this session's mounts"
    end
  end

  # An agent that takes its task, writes down that it did, and exits before it answers:
  # the program somebody else wrote falling over mid-task.
  defp quitting_agent(base, starts) do
    path = Path.join(base, "quitting-acp-agent.exs")

    File.write!(path, """
    defmodule QuittingACPAgent do
      def loop do
        case IO.read(:stdio, :line) do
          :eof ->
            :ok

          line ->
            line |> String.trim() |> handle()
            loop()
        end
      end

      defp handle(line) do
        case JSON.decode(line) do
          {:ok, %{"method" => "initialize", "id" => id}} ->
            reply(id, %{"protocolVersion" => 1})

          {:ok, %{"method" => "session/new", "id" => id}} ->
            reply(id, %{"sessionId" => "acp-1"})

          {:ok, %{"method" => "session/prompt"}} ->
            File.write!(#{inspect(starts)}, "started\\n", [:append])
            System.halt(3)

          _other ->
            :ok
        end
      end

      defp reply(id, result) do
        IO.puts(JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
      end
    end

    QuittingACPAgent.loop()
    """)

    path
  end

  describe "a subprocess that exits" do
    # A delegate runs its task once. Under the DynamicSupervisor a parent starts it in, one
    # whose program exits mid-task must not be started again and run its task a second
    # time, with nobody left waiting for its answer (defects D25).
    test "is reported as partial and not started again", context do
      starts = Path.join(context.base, "starts.log")
      sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      parent_ref = make_ref()

      entry = %{
        name: "quitter",
        command: System.find_executable("elixir"),
        args: [quitting_agent(context.base, starts)],
        hash: nil
      }

      {:ok, pid} =
        DynamicSupervisor.start_child(
          sup,
          {ACPAgent,
           session_id: "s-acp",
           agent_path: ["root", "quitter#1"],
           workspace: context.workspace,
           entry: entry,
           task: "have a look",
           parent: self(),
           parent_ref: parent_ref}
        )

      monitor = Process.monitor(pid)
      assert_receive {:child_result, ^parent_ref, {:partial, _said, _usage}}, 30_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000

      # Nothing started in its place, and nothing reports twice: a restarted delegate would
      # be under the supervisor at once, starting its program to be handed the task again.
      refute_receive {:child_result, ^parent_ref, _result}, 3_000
      assert DynamicSupervisor.which_children(sup) == []
      assert File.read!(starts) == "started\n"
    end
  end

  describe "a method nobody implements" do
    test "is method_not_found, not silence", context do
      assert {:error, %{"code" => -32_601}} =
               ACPAgent.serve("session/request_permission", %{}, context.workspace)
    end
  end
end
