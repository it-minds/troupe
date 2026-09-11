defmodule Troupe.Watch.WatcherTest do
  @moduledoc """
  Watch mode, run once against each backend.

  The agent is stood in for by the test process, registered under an agent path the
  watcher will send to. That isolates what is being tested — markers, debouncing,
  ignore rules and self-write suppression — from the agent loop, which has its own
  tests.
  """

  use ExUnit.Case, async: true

  alias Troupe.{Session, Workspace}
  alias Troupe.Watch.{Backend, FileSystemBackend, PollBackend}

  @stub_path ["stub"]

  setup do
    root = Path.join(System.tmp_dir!(), "troupe-watch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    # Ignore rules exist before watching starts, which is the realistic case; a
    # `.gitignore` written mid-session is covered separately below.
    File.write!(Path.join(root, ".gitignore"), "secret/\n*.log\n")

    {:ok, workspace} = Workspace.new(root)
    session_id = "watch-#{System.unique_integer([:positive])}"

    # Stand in for the root agent so the watcher's delivery can be observed directly.
    {:ok, _} = Registry.register(Troupe.Registry, {:agent, session_id, @stub_path}, nil)

    %{root: root, workspace: workspace, session_id: session_id}
  end

  for {name, backend} <- [native: FileSystemBackend, poll: PollBackend] do
    describe "#{name} backend" do
      @backend backend

      setup context do
        # The native watcher needs a platform executable a clean machine does not
        # have. Skipping there is the honest outcome: the polling backend covers the
        # same behaviour and is exactly what such a machine runs instead.
        if Backend.usable?(@backend, context.root) do
          %{watcher: start_watcher(context, @backend), available?: true}
        else
          %{available?: false}
        end
      end

      test "an AI! comment triggers exactly one input carrying file, line and comment",
           context do
        run_if_available(context, &assert_single_trigger/1)
      end

      test "five writes inside the debounce window produce one trigger", context do
        run_if_available(context, &assert_debounced/1)
      end

      test "the harness's own write does not retrigger", context do
        run_if_available(context, &assert_no_self_trigger/1)
      end

      test "a gitignored file's marker is ignored", context do
        run_if_available(context, &assert_ignored/1)
      end
    end
  end

  defp start_watcher(context, backend) do
    start_supervised!(
      {Session.Watcher,
       session_id: context.session_id,
       workspace: context.workspace,
       agent_path: @stub_path,
       enabled: true,
       backend: backend,
       debounce_ms: 150,
       poll_interval_ms: 60}
    )
  end

  defp assert_single_trigger(context) do
    # A bare AI comment elsewhere in the workspace rides along as context.
    write(context, "notes.md", "<!-- AI the invariant here is that ids are stable -->\n")

    write(
      context,
      "lib/math.ex",
      "defmodule Math do\n  # make this return 42 AI!\n  def answer, do: 0\nend\n"
    )

    trigger = assert_trigger()

    assert [marker] = trigger.markers
    assert marker.file == "lib/math.ex"
    assert marker.line == 2
    assert marker.comment == "make this return 42"
    assert marker.kind == :change
    assert marker.context =~ "def answer, do: 0"
    assert trigger.mode == :change

    assert [context_marker] = trigger.context
    assert context_marker.file == "notes.md"
    assert context_marker.comment =~ "invariant"

    refute_receive {:input, :watch, _, _, _}, 400
  end

  defp assert_debounced(context) do
    for n <- 1..5 do
      write(context, "lib/burst.ex", "# change number #{n} AI!\ndef x, do: #{n}\n")
    end

    trigger = assert_trigger()
    assert [marker] = trigger.markers
    assert marker.file == "lib/burst.ex"

    # One scan for the burst, and nothing after it.
    refute_receive {:input, :watch, _, _, _}, 500
  end

  defp assert_no_self_trigger(context) do
    path = Path.join(context.root, "lib/own.ex")
    File.mkdir_p!(Path.dirname(path))
    contents = "# the agent wrote this AI!\ndef y, do: 1\n"

    # Exactly what write_file and edit_file do: announce, then write.
    Troupe.Watch.expect_write(context.watcher, path, contents)
    File.write!(path, contents)

    refute_receive {:input, :watch, _, _, _}, 700

    # A human editing the same file afterwards must still trigger: the expectation
    # is consumed by the write it described, not standing forever.
    File.write!(path, "# a person wrote this AI!\ndef y, do: 2\n")
    trigger = assert_trigger()
    assert [marker] = trigger.markers
    assert marker.comment == "a person wrote this"
  end

  defp assert_ignored(context) do
    write(context, "secret/hidden.ex", "# do the thing AI!\n")
    write(context, "noisy.log", "# also this AI!\n")

    refute_receive {:input, :watch, _, _, _}, 700

    # Prove the watcher is alive and would have fired for a non-ignored file.
    write(context, "lib/visible.ex", "# this one counts AI!\n")
    trigger = assert_trigger()
    assert [marker] = trigger.markers
    assert marker.file == "lib/visible.ex"
  end

  defp run_if_available(%{available?: false}, _fun), do: :ok
  defp run_if_available(context, fun), do: fun.(context)

  defp assert_trigger(timeout \\ 4_000) do
    receive do
      {:input, :watch, trigger, _actor, _meta} -> trigger
    after
      timeout -> flunk("expected a watch trigger within #{timeout}ms")
    end
  end

  describe "ignore rules added mid-session" do
    setup context do
      %{watcher: start_watcher(context, PollBackend)}
    end

    test "a .gitignore written while watching starts applying", context do
      write(context, "build_out/a.ex", "# should trigger for now AI!\n")
      assert_trigger()

      write(context, ".gitignore", "secret/\n*.log\nbuild_out/\n")
      # The rule reaches the watcher through the .gitignore change event itself.
      write(context, "build_out/b.ex", "# should not trigger AI!\n")

      refute_receive {:input, :watch, _, _, _}, 800
    end
  end

  defp write(context, relative, contents) do
    path = Path.join(context.root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end
end
