defmodule Troupe.SurveyTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.Workspace.Survey

  describe "build/2" do
    test "detects language mix, project markers and their names" do
      ws =
        tmp_workspace(%{
          "mix.exs" => "defmodule X.MixProject do\n  def project, do: [app: :my_app]\nend\n",
          "lib/a.ex" => "defmodule A do\nend\n",
          "lib/b.ex" => "defmodule B do\nend\n",
          "assets/package.json" => ~s({"name": "my-assets"}\n),
          "assets/app.ts" => "export const x = 1\n",
          "README.md" => "# hi\n"
        })

      survey = Survey.build(ws)

      assert survey.total == 6
      assert {"Elixir", 3} in survey.languages
      assert {"TypeScript", 1} in survey.languages

      assert %{path: "mix.exs", label: "Elixir/Mix", detail: "my_app"} in survey.markers
      assert %{path: "assets/package.json", label: "Node", detail: "my-assets"} in survey.markers
    end

    test "walks the filesystem when there is no git repo, pruning build directories" do
      ws =
        tmp_workspace(%{
          "lib/a.ex" => "",
          "_build/junk.ex" => "",
          "node_modules/pkg/index.js" => "",
          "deps/dep/mix.exs" => ""
        })

      survey = Survey.build(ws)

      assert survey.vcs == :none
      assert survey.files == ["lib/a.ex"]
    end

    test "uses git for the file list and reports the branch" do
      ws = tmp_workspace(%{"lib/a.ex" => "", "ignored.log" => "", ".gitignore" => "*.log\n"})
      git_init!(ws)

      survey = Survey.build(ws)

      assert survey.vcs == :git
      assert survey.branch == "main"
      assert "lib/a.ex" in survey.files
      refute "ignored.log" in survey.files
    end

    test "lists every file when the listing fits the budget" do
      ws = tmp_workspace(%{"lib/a.ex" => "", "lib/b.ex" => ""})

      assert Survey.build(ws, git: false).listing == :files
    end

    test "falls back to directory counts when the listing is too large" do
      files = Map.new(1..40, fn i -> {"lib/nested/file_#{i}.ex", ""} end)
      ws = tmp_workspace(files)

      survey = Survey.build(ws, git: false, max_chars: 100)

      assert survey.listing == :dirs
      assert {"lib/nested", 40} in survey.dirs
    end
  end

  describe "render/1" do
    test "renders a file listing an agent can pick a first file from" do
      ws = tmp_workspace(%{"mix.exs" => "app: :demo", "lib/demo.ex" => ""})

      text = Survey.build(ws, git: false) |> Survey.render()

      assert text =~ "# Workspace"
      assert text =~ "mix.exs (Elixir/Mix: demo)"
      assert text =~ "Languages: Elixir 2"
      assert text =~ "## Files (2 files)"
      assert text =~ "lib/demo.ex"
    end

    test "renders the directory summary when the listing is too large" do
      files = Map.new(1..40, fn i -> {"lib/nested/file_#{i}.ex", ""} end)
      ws = tmp_workspace(files)

      text = Survey.build(ws, git: false, max_chars: 100) |> Survey.render()

      assert text =~ "## Layout (40 files"
      assert text =~ "lib/nested/ — 40"
      assert text =~ "Use `list_files`"
    end

    test "is empty for an empty workspace" do
      assert Survey.build(tmp_workspace(), git: false) |> Survey.render() == ""
    end
  end

  describe "system prompt" do
    test "the agent's first request already carries the workspace layout" do
      ws = tmp_workspace(%{"mix.exs" => "app: :demo", "lib/demo.ex" => "defmodule Demo do\nend\n"})

      {sid, fake, _ws} = start_session!(workspace: ws, script: [{:finish, "done"}])
      {:ok, "code-1"} = Troupe.dispatch(sid, "code", "orient yourself")
      await_state("code-1", :done_unread, 15_000)

      [req | _] = Troupe.LLM.Fake.requests(fake)
      assert req.system =~ "# Workspace"
      assert req.system =~ "lib/demo.ex"
      assert req.system =~ "Elixir/Mix: demo"
    end
  end
end
