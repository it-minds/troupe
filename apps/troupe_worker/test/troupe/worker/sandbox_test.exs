defmodule Troupe.Worker.SandboxTest do
  @moduledoc """
  On a worker every command a session's tools start runs in the sandbox, whatever the
  session's mounts or bundle (#528, Decision 832).

  A session resumed with no mounts of its own and no bundle ran `shell` outside the
  sandbox, on the volume it shares with the other sessions on that pod: `Troupe.Sandbox`'s
  `:auto` wraps a command only for a session with a mount besides its workspace, and
  nothing set anything else. The setting here is the worker's own, read from
  `config/runtime.exs` as a pod reads it, and every check is the kernel's: a file beside
  the workspace, where another session's would be, is not there for the command.

  A worker that cannot start the sandbox refuses the command with a sentence and says so
  once in its log. Skipped loudly where bubblewrap is not installed, as core's
  `Troupe.SandboxTest` is: those cases need a sandbox that starts.
  """

  use Troupe.Worker.SessionCase, async: false

  import ExUnit.CaptureLog

  alias Troupe.Protocol.Event
  alias Troupe.Sandbox

  @moduletag timeout: 120_000

  setup context do
    # What a pod's `runtime.exs` sets, applied as a pod applies it. Global, which is why
    # every test in this app is synchronous, and removed again so no other suite runs in it.
    case worker_config()[:troupe_core][:sandbox] do
      nil -> :ok
      mode -> Application.put_env(:troupe_core, :sandbox, mode)
    end

    on_exit(fn -> Application.delete_env(:troupe_core, :sandbox) end)

    if context[:store] do
      # Where another session's workspace would be: beside this one, on the same volume.
      other = Path.join(context.base, "other-session")
      File.mkdir_p!(other)
      File.write!(Path.join(other, "theirs.txt"), "the-other-sessions-work")
      Map.put(context, :other, other)
    else
      context
    end
  end

  test "the worker's configuration sandboxes every command, and only a worker's does" do
    assert worker_config()[:troupe_core][:sandbox] == :always
    assert laptop_config()[:troupe_core][:sandbox] == nil
  end

  describe "a session with no mounts and no bundle" do
    test "runs `shell` in the sandbox, where another session's files are not", context do
      context = requires_tier(context)
      requires_bubblewrap!()
      theirs = Path.join(context.other, "theirs.txt")

      {:ok, _} =
        activate(context,
          steps: [
            {:tools, [{"shell", %{"command" => "cat #{theirs}; echo; echo home=$HOME"}}]},
            {:text, "done"}
          ]
        )

      completed = tool_result(context.session_id, "shell", "look next door")

      assert completed["ok"] == true
      assert completed["content"] =~ "No such file or directory"
      refute completed["content"] =~ "the-other-sessions-work"
      # The namespace's `$HOME`, not the pod user's, which every session on it shares.
      assert completed["content"] =~ "home=#{context.workspace}"
    end

    # How the command ended is a field of its event in the sandbox as on a laptop (#248,
    # Decision 837): the status is the command's, not the sandbox's.
    test "records how `shell`'s command ended beside `ok`, as a laptop does", context do
      context = requires_tier(context)
      requires_bubblewrap!()

      {:ok, _} =
        activate(context,
          steps: [
            {:tools, [{"shell", %{"command" => "echo ok"}}]},
            {:tools, [{"shell", %{"command" => "printf no; exit 3"}}]},
            {:text, "done"}
          ]
        )

      [passed, failed] = tool_results(context.session_id, "shell", "run both", 2)

      assert {passed["ok"], passed["exit_status"], passed["content"]} == {true, 0, "ok\n"}
      assert {failed["ok"], failed["exit_status"]} == {true, 3}
      assert failed["content"] == "no\n\n[exit status 3]"
      refute Map.has_key?(passed, "timed_out") or Map.has_key?(failed, "timed_out")
    end

    test "runs `git_read`'s git there too, where a repository outside the workspace is not",
         context do
      context = requires_tier(context)
      requires_bubblewrap!()

      # A repository beside the workspace, which the workspace's `.git` names.
      repository = Path.join(context.other, "repo")
      git!(["init", "-q", repository])

      git!([
        "-C",
        repository,
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.com",
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "the other session's commit"
      ])

      File.write!(Path.join(context.workspace, ".git"), "gitdir: #{repository}/.git\n")

      {:ok, _} =
        activate(context,
          steps: [{:tools, [{"git_read", %{"op" => "log"}}]}, {:text, "done"}]
        )

      completed = tool_result(context.session_id, "git_read", "what changed")

      refute completed["content"] =~ "the other session's commit"
      assert completed["ok"] == false
      assert completed["content"] =~ "not a git repository"
    end
  end

  describe "a worker that cannot start the sandbox" do
    test "without bubblewrap refuses `shell` with a sentence, and logs it once", context do
      context = requires_tier(context)
      Application.put_env(:troupe_core, :bwrap, Path.join(context.base, "no-bwrap"))
      on_exit(fn -> Application.delete_env(:troupe_core, :bwrap) end)

      {first, second, log} = twice(context, "touch ran-it")

      for completed <- [first, second] do
        assert completed["ok"] == false
        assert completed["content"] =~ "runs every command in a sandbox"
        assert completed["content"] =~ "bubblewrap is not installed"
        # No command ran, so none ended (Decision 837).
        refute Map.has_key?(completed, "exit_status") or Map.has_key?(completed, "timed_out")
      end

      refute File.exists?(Path.join(context.workspace, "ran-it"))
      assert length(Regex.scan(~r/bubblewrap is not installed/, log)) == 1
    end

    test "with a bubblewrap the kernel refuses says what it said, and logs it once", context do
      context = requires_tier(context)

      # A `bwrap` that answers as one does where unprivileged user namespaces are off.
      refused = Path.join(context.base, "bwrap")

      File.write!(refused, """
      #!/bin/sh
      echo 'bwrap: No permissions to create a new namespace' >&2
      exit 1
      """)

      File.chmod!(refused, 0o755)
      Application.put_env(:troupe_core, :bwrap, refused)
      on_exit(fn -> Application.delete_env(:troupe_core, :bwrap) end)

      {first, second, log} = twice(context, "touch ran-it")

      for completed <- [first, second] do
        assert completed["ok"] == false
        assert completed["content"] =~ "could not start one"
        assert completed["content"] =~ "No permissions to create a new namespace"
        # The sandbox's own exit is not a command's (Decision 837).
        refute Map.has_key?(completed, "exit_status")
      end

      refute File.exists?(Path.join(context.workspace, "ran-it"))
      assert length(Regex.scan(~r/could not start one/, log)) == 1
    end
  end

  # -- helpers ----------------------------------------------------------------

  # Two `shell` calls in one turn, both answered, and what the worker logged meanwhile.
  defp twice(context, command) do
    log =
      capture_log(fn ->
        {:ok, _} =
          activate(context,
            steps: [
              {:tools, [{"shell", %{"command" => command}}]},
              {:tools, [{"shell", %{"command" => command}}]},
              {:text, "done"}
            ]
          )

        send(self(), {:results, tool_results(context.session_id, "shell", "try it", 2)})
      end)

    assert_received {:results, [first, second]}
    {first, second, log}
  end

  defp tool_result(session_id, name, input) do
    [completed] = tool_results(session_id, name, input, 1)
    completed
  end

  defp tool_results(session_id, name, input, count) do
    :ok = Troupe.subscribe(session_id)
    Troupe.send_input(session_id, input)

    for _ <- 1..count do
      receive do
        {:troupe_event, ^session_id,
         %Event{type: "tool_call_completed", data: %{"name" => ^name} = completed}} ->
          completed
      after
        30_000 -> flunk("no #{name} result")
      end
    end
  after
    Troupe.unsubscribe(session_id)
  end

  defp requires_bubblewrap! do
    unless Sandbox.available?() do
      IO.puts(
        :stderr,
        "\nSKIPPED: bubblewrap is not installed; a worker's sandbox is unchecked.\n"
      )

      flunk("no bubblewrap; a worker's `shell` confinement is unchecked")
    end
  end

  defp git!(args) do
    {_output, 0} = System.cmd("git", args, stderr_to_stdout: true)
  end

  # `config/runtime.exs` as a release reads it: a worker's, which the operator and a
  # host's service mark with `TROUPE_WORKER_AUTOSTART`, and a machine's that is not one.
  defp worker_config, do: runtime_config(%{"TROUPE_WORKER_AUTOSTART" => "true"})
  defp laptop_config, do: runtime_config(%{"TROUPE_WORKER_AUTOSTART" => nil})

  defp runtime_config(vars) do
    previous = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)
    Enum.each(vars, fn {name, value} -> put_env(name, value) end)

    try do
      "../../../../../config/runtime.exs"
      |> Path.expand(__DIR__)
      |> Config.Reader.read!(env: :prod, target: :host)
    after
      Enum.each(previous, fn {name, value} -> put_env(name, value) end)
    end
  end

  defp put_env(name, nil), do: System.delete_env(name)
  defp put_env(name, value), do: System.put_env(name, value)
end
