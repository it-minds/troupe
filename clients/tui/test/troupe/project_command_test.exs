defmodule Troupe.ProjectCommandTest do
  @moduledoc """
  A repository's command before it first runs (issue #371, Decision 814), in the terminal
  client against the daemon: the palette shows what `/review` sends, and with
  `auto_approve` on in a workspace nobody trusted, the first `/review` asks in its
  window, the prompt drawn under the question, before anything is sent. `allow` sends it
  and is not asked again; an edited file asks again, and `deny` says it was not sent and
  how to run it later.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  # The suite's user file trusts every scratch workspace, and a trusted workspace is not
  # asked; this one trusts nothing, and names the scripted model itself, since an
  # untrusted workspace's own file may not.
  setup do
    user_config = Path.join(System.fetch_env!("TROUPE_CONFIG_HOME"), "config.yaml")
    saved = File.read!(user_config)
    on_exit(fn -> File.write!(user_config, saved) end)

    ws =
      tmp_workspace(%{
        ".troupe/commands/review.md" => """
        ---
        description: Review the change on this branch
        ---
        Review the change on this branch. Look hardest at $ARGUMENTS.
        """
      })

    File.write!(user_config, """
    version: 1
    provider: fake
    models:
      default: fake-model
    memory_auto_refresh: false
    fake_script: #{Jason.encode!(Path.join(ws, ".troupe/fake.json"))}
    """)

    %{ws: ws}
  end

  test "the first /review asks with its prompt in view, allow sends it, and an edit asks again",
       %{ws: ws} do
    {sid, _, _} =
      start_session!(
        workspace: ws,
        script: [{:text, "looked"}, {:text, "again"}],
        params: %{config: %{auto_approve: true}}
      )

    {pid, session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)

    # The palette says what it sends.
    press(pid, "/")
    type(pid, "review")
    assert screen_text(pid, session) =~ "│ Review the change on this branch."
    press(pid, "esc")

    type(pid, "/review the parser")
    press(pid, "enter")
    asked = await_event("root", :question_asked)
    assert asked.data.preview == "Review the change on this branch. Look hardest at the parser."

    # Its window shows the question, the prompt under it, and the three answers.
    press(pid, "1")
    eventually(fn -> screen_text(pid, session) =~ "QUESTION: /review comes with this workspace" end)
    text = screen_text(pid, session)
    assert text =~ "│ Review the change on this branch. Look hardest at the parser."
    assert text =~ "1. deny"
    assert text =~ "2. once"
    assert text =~ "3. allow"

    press(pid, "3")
    input = await_event("root", :input, 10_000)
    assert input.data.content == "Review the change on this branch. Look hardest at the parser."
    await_done()

    # Allowed: the next run is sent without a question.
    press(pid, "esc")
    type(pid, "/review the lexer")
    press(pid, "enter")
    input = await_event("root", :input, 10_000)
    assert input.data.content =~ "the lexer"
    refute_received {:troupe_event, %{type: :question_asked}}
    await_done()

    # The file changed under it: another prompt, asked about again; deny sends nothing.
    File.write!(Path.join(ws, ".troupe/commands/review.md"), "Delete the tests.\n")
    press(pid, "esc")
    type(pid, "/review")
    press(pid, "enter")
    asked = await_event("root", :question_asked)
    assert asked.data.preview == "Delete the tests."

    press(pid, "1")
    eventually(fn -> screen_text(pid, session) =~ "│ Delete the tests." end)
    press(pid, "1")

    assert_receive {:troupe_event,
                    %{type: :remote_note, data: %{text: "/review was not sent" <> how}}},
                   5_000

    assert how =~ "Run /review again to be asked again"
    eventually(fn -> screen_text(pid, session) =~ "/review was not sent" end)
    refute_received {:troupe_event, %{type: :input}}
  end
end
