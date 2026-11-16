defmodule Troupe.ClientLeftoversTest do
  @moduledoc """
  What the desktop app had and the terminal did not (#956). A call's approval box offers
  Always allow where the daemon names `approval_allow_always`: `w` asks where the rule goes,
  `w` again for this workspace and `g` for everywhere, Esc back; the key line keeps it at 80
  columns; a pod names none, so the box offers no `w`, and one pressed anyway is the pod's
  refusal in its words. `/artifacts` from a window is the picker for its message: `a`
  attaches the artifact on the cursor, the window's box says so before it is sent, and
  the message says where each file landed after. Where two or more people steer, an
  answered question says who answered it; with one, it is drawn as ever.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.{Client, Event}
  alias Troupe.Client.Daemon.Link
  alias Troupe.FakeRemote
  alias Troupe.Remote.Translate
  alias Troupe.UI.TUI.Model

  @moduletag timeout: 120_000

  # Always allow everywhere writes the person's config.yaml, which the suite shares: put it
  # back as it was, so no later session runs the tool unasked.
  setup do
    config = Troupe.Paths.config_file("config.yaml")
    was = File.read(config)

    on_exit(fn ->
      case was do
        {:ok, text} -> File.write!(config, text)
        {:error, _none} -> File.rm(config)
      end
    end)

    :ok
  end

  @script [
    {:text_and_tools, "Let me write that.",
     [{"write_file", %{"path" => "note.txt", "content" => "from the box\n"}}]},
    {:text, "Done writing."},
    {:finish, "wrote note.txt"}
  ]

  defp asking(opts \\ []) do
    ws = tmp_workspace()
    {sid, _, _} = start_session!(workspace: ws, script: @script, auto_approve: false)
    {pid, session} = start_tui(sid, opts)

    type(pid, "please write a note")
    press(pid, "enter")
    await_event("build-1", :approval_requested)
    eventually(fn -> Model.always_allow?(user_state(pid).model) end)
    press(pid, "1")
    eventually(fn -> user_state(pid).focus == {:window, "build-1"} end)
    {pid, session, ws}
  end

  describe "Always allow on a call's approval" do
    test "w asks where, Esc goes back, and g writes the rule everywhere and allows the call" do
      {pid, session, ws} = asking()

      eventually(fn ->
        screen_text(pid, session) =~
          "APPROVAL: write_file (y allow / n deny / a allow for session / w always allow)"
      end)

      assert screen_text(pid, session) =~ "y/n/a approve · w always"

      press(pid, "w")

      eventually(fn ->
        screen_text(pid, session) =~
          "Always allow write_file where? w this workspace (.troupe/config.local.yaml) · " <>
            "g everywhere (your config.yaml) · Esc back"
      end)

      border = Enum.find(screen(pid, session), &(&1 =~ "└ PgUp"))
      assert border =~ "w workspace · g everywhere · Esc", border
      refute File.exists?(Path.join(ws, "note.txt"))

      # Esc: the approval waits with its answers, as before.
      press(pid, "esc")
      eventually(fn -> user_state(pid).always == nil end)
      refute screen_text(pid, session) =~ "where? w this workspace"
      assert user_state(pid).focus == {:window, "build-1"}

      press(pid, "w")
      eventually(fn -> user_state(pid).always != nil end)
      press(pid, "g")

      await_state("build-1", :done, 10_000)
      assert File.read!(Path.join(ws, "note.txt")) == "from the box\n"

      assert Enum.any?(
               user_state(pid).model.notices,
               &(&1 =~ "always allowed write_file everywhere (your config.yaml)")
             )

      assert File.read!(Troupe.Paths.config_file("config.yaml")) =~ "write_file"
    end

    test "w twice asks for this workspace, and a refusal is said in the daemon's words" do
      {pid, _session, ws} = asking()
      press(pid, "w")
      eventually(fn -> user_state(pid).always != nil end)
      press(pid, "w")

      eventually(fn ->
        Enum.any?(
          user_state(pid).model.notices,
          &(&1 =~ "always allowed write_file" or &1 =~ "not always allowed")
        )
      end)

      notice = Enum.find(user_state(pid).model.notices, &(&1 =~ "always allowed"))

      if notice =~ "not always allowed" do
        # A workspace not trusted holds a project's allow, so the daemon refuses it there
        # and says how to trust it; the call still waits for its answer.
        assert notice =~ "trust"
        refute File.exists?(Path.join(ws, "note.txt"))
      else
        assert notice =~ "in this workspace (.troupe/config.local.yaml)"
        assert File.read!(Path.join([ws, ".troupe", "config.local.yaml"])) =~ "write_file"
      end
    end

    test "the key line keeps Always allow at 80 columns, and the question's keys" do
      {pid, session, _ws} = asking(width: 80)
      rows = screen(pid, session)
      line = Enum.find(rows, &(&1 =~ "└" and &1 =~ "y/n/a"))
      assert line, "no border keeps the answers at 80 columns:\n" <> Enum.join(rows, "\n")
      assert line =~ "y/n/a/w"

      press(pid, "w")
      eventually(fn -> user_state(pid).always != nil end)
      rows = screen(pid, session)
      assert Enum.any?(rows, &(&1 =~ "g everywhere")), Enum.join(rows, "\n")
      assert Enum.all?(rows, &(String.length(&1) <= 80))
    end

    test "from another device w says the call is answered once" do
      {pid, session, _ws} = asking()
      sid = user_state(pid).session_id
      send(pid, {:troupe_event, Event.transient(sid, "root", :remote_status, %{relayed?: true})})
      eventually(fn -> Model.relayed?(user_state(pid).model) end)
      refute Model.always_allow?(user_state(pid).model)
      refute screen_text(pid, session) =~ "w always"

      press(pid, "w")

      eventually(fn ->
        Enum.any?(user_state(pid).model.notices, &(&1 =~ "a call is allowed or denied once"))
      end)
    end
  end

  describe "on a pod" do
    @refusal "rules on the platform are the worker profile's, which an administrator sets; " <>
               "allow it once or for this session"

    test "the box offers no w, and one pressed anyway is the pod's refusal" do
      {remote, url} =
        start_remote!(sessions: [FakeRemote.session(id: "s-pod", profile: "code")])

      origin = connect!(remote, url)
      sid = attach!(origin, "s-pod")
      eventually(fn -> Client.capability(sid).up? end)
      {pid, session} = start_tui(sid)

      FakeRemote.emit(remote, "s-pod", "approval_requested", %{
        "call_id" => "c1",
        "tool" => "shell",
        "args" => %{"command" => "make test"},
        "agent_path" => ["code-1"]
      })

      eventually(fn -> user_state(pid).model.windows["code-1"] != nil end)
      press(pid, "1")
      eventually(fn -> user_state(pid).focus == {:window, "code-1"} end)

      eventually(fn ->
        screen_text(pid, session) =~ "APPROVAL: shell (y allow / n deny / a allow for session)"
      end)

      refute screen_text(pid, session) =~ "w always"
      refute Model.always_allow?(user_state(pid).model)

      FakeRemote.fail_next(remote, "approval.respond", -32_004, "forbidden",
        data: %{"reason" => @refusal}
      )

      press(pid, "w")

      eventually(fn ->
        Enum.any?(user_state(pid).model.notices, &(&1 =~ "not always allowed" and &1 =~ @refusal))
      end)

      assert Enum.any?(
               FakeRemote.calls(remote),
               &match?({"approval.respond", %{"decision" => "allow_always"}}, &1)
             )
    end
  end

  describe "an artifact attached to the message" do
    @notes "# Release plan\n\n- ship it\n"

    @rows [
      %{
        "id" => "a-plan",
        "title" => "Release plan",
        "kind" => "markdown",
        "visibility" => "private",
        "scope" => "private",
        "mine" => true,
        "version" => 2,
        "published_at" => "2026-11-15T10:00:00Z"
      }
    ]

    setup do
      seen = Path.join(Troupe.Paths.state_dir(), "artifacts-seen.json")
      File.rm(seen)
      on_exit(fn -> File.rm(seen) end)
      :ok
    end

    test "/artifacts from a window picks it with a, the box shows it, and the message says where it landed" do
      {remote, url} =
        start_remote!(transport: :http, artifacts: @rows, artifact_texts: %{"a-plan" => @notes})

      login!(remote, url)
      reattach()
      eventually(fn -> match?({:ok, %{"linked" => true}}, Link.call("identity.get", %{})) end)

      ws = tmp_workspace()
      {sid, _, ws} = start_session!(workspace: ws, script: [{:text, "Hello."}, {:text, "Read it."}])
      {pid, session} = start_tui(sid)
      eventually(fn -> Model.attach_artifact?(user_state(pid).model) end)
      path = window(pid, sid)

      type(pid, "/artifacts")
      press(pid, "enter")
      eventually(fn -> user_state(pid).focus == :artifacts end)
      assert screen_text(pid, session) =~ "attach to #{path} — a attaches it to the message"
      eventually(fn -> screen_text(pid, session) =~ "Release plan" end)

      press(pid, "a")
      eventually(fn -> user_state(pid).focus == {:window, path} end)
      assert screen_text(pid, session) =~ "+ “Release plan” v2 — Enter sends it with the message"

      type(pid, "read the plan")
      press(pid, "enter")

      eventually(fn -> File.read(Path.join(ws, "index.md")) == {:ok, @notes} end)
      eventually(fn -> user_state(pid).attached == %{} end)

      eventually(fn ->
        screen_text(pid, session) =~ "uploaded index.md to session:/index.md"
      end)

      assert screen_text(pid, session) =~ "read the plan"
      refute screen_text(pid, session) =~ "+ “Release plan”"
    end

    test "Backspace in the empty box takes it off, and a window under Local only is not offered a" do
      {sid, _, _} = start_session!(script: [{:text, "Hello."}])
      {pid, session} = start_tui(sid)
      path = window(pid, sid)

      :sys.replace_state(pid, fn s ->
        put_in(s.user_state.attached, %{path => %{id: "a-plan", title: "Release plan", version: 2}})
      end)

      assert screen_text(pid, session) =~ "+ “Release plan” v2"
      press(pid, "backspace")
      eventually(fn -> user_state(pid).attached == %{} end)
      refute screen_text(pid, session) =~ "+ “Release plan”"
    end
  end

  # The session's own window, opened by a first turn and focused, as a person opens it.
  defp window(pid, sid) do
    say!(sid, "hello")

    eventually(
      fn -> match?(%{state: s} when s != :running, user_state(pid).model.windows["root"]) end,
      10_000
    )

    press(pid, "1")
    eventually(fn -> user_state(pid).focus == {:window, "root"} end)
    "root"
  end

  # The daemon's link reads the sign-in `login!` wrote once it dials again.
  defp reattach do
    case :sys.get_state(Link) do
      %{client: client} when is_pid(client) -> Troupe.Protocol.Client.close(client)
      _ -> :ok
    end

    {:ok, _} = Link.call("identity.get", %{})
  end

  describe "who answered a question" do
    defp event(seq, type, data, actor) do
      %{
        "seq" => seq,
        "prev_hash" => "sha256:abc",
        "ts" => "2026-11-15T10:00:00.000Z",
        "actor" => actor,
        "agent" => ["root"],
        "type" => type,
        "v" => 1,
        "data" => data
      }
    end

    @me %{"kind" => "user", "subject" => "idp|martin", "display_name" => "Martin"}
    @bob %{"kind" => "user", "subject" => "idp|bob", "display_name" => "Bob Example"}
    @asked %{
      "call_id" => "q-1",
      "question" => "Which branch?",
      "options" => [],
      "multiple" => false
    }

    defp lines(events, model \\ Model.new("s-1", ".")) do
      memory = Translate.me(Translate.memory(), "idp|martin")

      {model, _memory} =
        Enum.reduce(events, {model, memory}, fn event, {model, memory} ->
          {local, memory} = Translate.durable("s-1", event, memory)
          {Enum.reduce(local, model, &Model.apply(&2, &1)), memory}
        end)

      model
      |> Model.windows()
      |> Enum.flat_map(fn w -> Enum.flat_map(Map.values(w.agents), & &1.transcript) end)
      |> Enum.flat_map(fn
        {:system, text} -> [text]
        _other -> []
      end)
    end

    test "another person's answer says who gave it" do
      events = [
        event(1, "question_asked", @asked, @me),
        event(2, "question_answered", %{"call_id" => "q-1", "text" => "main"}, @bob)
      ]

      assert "“Which branch?” answered by Bob Example: main" in lines(events)
    end

    test "with one person steering, the answer leaves no line" do
      events = [
        event(1, "question_asked", @asked, @me),
        event(2, "question_answered", %{"call_id" => "q-1", "text" => "main"}, @me)
      ]

      refute Enum.any?(lines(events), &(&1 =~ "answered by"))
    end

    test "with another person here, the person's own answer says it was theirs" do
      events = [
        event(1, "question_asked", @asked, @me),
        event(2, "question_answered", %{"call_id" => "q-1", "text" => "main"}, @me)
      ]

      # Bob is attached to the session now, as its presence said.
      here = %{
        Model.new("s-1", ".")
        | present: %{{"idp|bob", nil} => %{name: "Bob Example", via: nil}}
      }

      assert "“Which branch?” answered by you: main" in lines(events, here)
    end
  end
end
