defmodule Troupe.Instructions.FrontMatterTest do
  @moduledoc """
  One reader for a rule's front matter (#516; Decisions 809, 827 and 828): the loader's
  `.troupe/rules/*.md` and onboarding's Cursor and Copilot rules read the same text the
  same way. On the chunk's tip each had its own copy, and they disagreed: a quoted
  comma-separated `globs: "docs/**,lib/**"` was two globs to onboarding and two broken
  ones to the loader, so a rule written by hand that way never joined.
  """

  use ExUnit.Case, async: true

  alias Troupe.Instructions
  alias Troupe.Instructions.FrontMatter

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-front-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  test "the keys and the body; none without a closed front matter" do
    assert FrontMatter.split("---\ndescription: Style\nglobs: *.ts\n---\n\nBody.\n") ==
             {%{"description" => ["Style"], "globs" => ["*.ts"]}, "Body."}

    assert FrontMatter.split("\uFEFF---\r\nalwaysApply: true\r\n---\r\nBody.\r\n") ==
             {%{"alwaysApply" => ["true"]}, "Body."}

    assert FrontMatter.split("---\nglobs: *.ts\nnever closed\n") ==
             {%{}, "---\nglobs: *.ts\nnever closed"}

    assert FrontMatter.split("  Just a body.\n") == {%{}, "Just a body."}
  end

  test "when a rule applies, from each form of its keys" do
    rule = fn text -> text |> FrontMatter.split() |> elem(0) |> FrontMatter.rule() end

    # The loader's forms (Decision 809).
    assert rule.("---\nglobs: [\"docs/*.md\", 'Makefile']\n---\nx").globs == [
             "docs/*.md",
             "Makefile"
           ]

    assert rule.("---\nglobs:\n  - \"lib/**\"\n- test/*.exs\n---\nx").globs == [
             "lib/**",
             "test/*.exs"
           ]

    assert rule.("---\nglobs: **/*.{ts,tsx}, a?.c\n---\nx").globs == ["**/*.{ts,tsx}", "a?.c"]
    assert rule.("---\nglobs: ./priv/\n---\nx").globs == ["./priv/"]

    # Onboarding's: one quoted string of several, as Copilot writes `applyTo`, and two
    # quoted items, each losing its own quotes.
    assert rule.("---\nglobs: \"**/*.ex,**/*.exs\"\n---\nx").globs == ["**/*.ex", "**/*.exs"]
    assert rule.("---\nglobs: \"a/**\", 'b/**'\n---\nx").globs == ["a/**", "b/**"]

    assert FrontMatter.globs(["\"**\""]) == ["**"]
    assert FrontMatter.globs(nil) == []

    assert rule.("---\ndescription: >\n  How the docs\n  are written\n---\nx") == %{
             always: false,
             globs: [],
             description: "How the docs are written"
           }

    assert rule.("---\nalwaysApply: True\ndescription: \"\"\n---\nx") == %{
             always: true,
             globs: [],
             description: nil
           }
  end

  test "the loader and onboarding read one front matter the same way", %{base: base} do
    repo = Path.join(base, "repo")
    write!(repo, ".git/HEAD", "ref: refs/heads/main\n")

    front = """
    ---
    description: Both ways
    globs: "docs/**,lib/**"
    ---
    Read alike.
    """

    write!(repo, ".troupe/rules/both.md", front)
    write!(repo, ".cursor/rules/both.mdc", front)

    loaded = Instructions.load(repo, nil, ["lib/a.ex"])

    assert [%{rule: %{globs: ["docs/**", "lib/**"]}, status: :whole} | _] =
             Enum.filter(loaded.files, &(Path.basename(&1.path) == "both.md"))

    [proposal] =
      Troupe.Onboard.Instructions.proposals(repo,
        home: Path.join(base, "home"),
        config_dir: Path.join(base, "config")
      )

    assert proposal.content =~ ~s(globs: ["docs/**", "lib/**"]\n)
  end

  defp write!(dir, relative, text) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end
end
