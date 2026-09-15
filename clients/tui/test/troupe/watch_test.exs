defmodule Troupe.WatchTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.LLM.Fake

  # Done item 26, once per backend
  for backend <- [:file_system, :polling] do
    @backend backend

    test "#{backend}: AI! spawns one quick branch with file, line, comment and context; debounced; own edits ignored; gitignored ignored; AI? spawns answer" do
      backend = @backend

      ws =
        tmp_workspace(%{
          "lib/calc.ex" => "defmodule Calc do\n  def answer, do: 0\nend\n",
          "lib/other.ex" => "# AI keep the public API stable\n",
          ".gitignore" => "ignored/\n",
          "ignored/x.ex" => "# nothing yet\n"
        })

      git_init!(ws)

      change_script = [
        {:tool, "edit_file",
         %{
           "path" => "lib/calc.ex",
           "old_string" => "  def answer, do: 0 # make this return 42 AI!\n",
           "new_string" => "  def answer, do: 42\n"
         }},
        {:finish, "returned 42"}
      ]

      question_script = [
        {:tool, "write_file", %{"path" => "lib/should_not.ex", "content" => "x"}},
        {:finish, "answered"}
      ]

      fake =
        Fake.start!([],
          scripts: %{"quick-1" => change_script, "answer-1" => question_script},
          fallback: {:finish, "unexpected"}
        )

      {sid, _, _} =
        start_session!(
          workspace: ws,
          fake: fake,
          auto_approve: true,
          config: %{watch: %{debounce_ms: 1_000}}
        )

      {:ok, ^backend} = Troupe.Session.Watcher.enable(sid, backend: backend)
      Process.sleep(600)

      # five writes inside one debounce window produce one branch
      path = Path.join(ws, "lib/calc.ex")

      for i <- 1..5 do
        File.write!(
          path,
          "defmodule Calc do\n  def answer, do: 0 # make this return 42 AI!\nend\n# rev #{i}\n"
        )

        Process.sleep(30)
      end

      File.write!(path, "defmodule Calc do\n  def answer, do: 0 # make this return 42 AI!\nend\n")

      assert_receive {:troupe_event,
                      %{type: :branch_spawned, agent_path: "quick-1", data: %{source: :watch}}},
                     10_000

      await_state("quick-1", :done_unread, 15_000)

      [first | _] = fake |> Fake.requests() |> Enum.filter(&(&1.agent_path == "quick-1"))
      prompt = first.messages |> hd() |> Map.get(:content) |> Troupe.LLM.Message.text()
      assert prompt =~ "lib/calc.ex:2: make this return 42 AI!"
      assert prompt =~ "def answer, do: 0"
      assert prompt =~ "lib/other.ex:1: AI keep the public API stable"
      assert File.read!(path) =~ "do: 42"

      # a saved comment is not worth the default model or a full thinking budget
      assert first.model == %Troupe.Config{}.models.cheap
      assert first.reasoning_effort == "low"

      # the harness's own edit and a gitignored marker do not retrigger
      File.write!(Path.join(ws, "ignored/x.ex"), "# change me AI!\n")
      Process.sleep(2_500)
      refute_received {:troupe_event, %{type: :branch_spawned, agent_path: "quick-2"}}
      assert Enum.count(Troupe.windows(sid), &(&1.name == "quick")) == 1

      # AI? spawns a read-only branch that answers and cannot write
      File.write!(
        Path.join(ws, "lib/calc.ex"),
        "defmodule Calc do\n  def answer, do: 42 # AI? is this idiomatic\nend\n"
      )

      assert_receive {:troupe_event,
                      %{type: :branch_spawned, agent_path: "answer-1", data: %{source: :watch}}},
                     10_000

      await_state("answer-1", :done_unread, 15_000)
      refute File.exists?(Path.join(ws, "lib/should_not.ex"))
      assert window(sid, "answer-1").summary == "answered"

      [ask | _] = fake |> Fake.requests() |> Enum.filter(&(&1.agent_path == "answer-1"))
      assert ask.model == %Troupe.Config{}.models.cheap
      assert ask.reasoning_effort == "none"
      assert Enum.map(ask.tools, & &1.name) == ~w(read_file list_files grep finish)
    end
  end

  test "the profile each marker dispatches is a setting" do
    ws = tmp_workspace(%{"lib/calc.ex" => "defmodule Calc do\nend\n"})
    git_init!(ws)

    fake =
      Fake.start!([],
        scripts: %{"plan-1" => [{:finish, "planned"}]},
        fallback: {:finish, "unexpected"}
      )

    {sid, _, _} =
      start_session!(
        workspace: ws,
        fake: fake,
        config: %{watch: %{debounce_ms: 100, question_command: "plan"}}
      )

    {:ok, :polling} = Troupe.Session.Watcher.enable(sid, backend: :polling)
    Process.sleep(400)

    File.write!(Path.join(ws, "lib/calc.ex"), "defmodule Calc do\nend\n# AI? what is this\n")

    assert_receive {:troupe_event,
                    %{type: :branch_spawned, agent_path: "plan-1", data: %{source: :watch}}},
                   10_000
  end
end
