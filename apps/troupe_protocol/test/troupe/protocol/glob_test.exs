defmodule Troupe.Protocol.GlobTest do
  @moduledoc """
  A glob turned into a regular expression: one translator for push rules, permissions,
  `.gitignore` lines and instruction files' globs.
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.Glob

  defp matches?(glob, subject, opts \\ []),
    do: Regex.match?(Regex.compile!("\\A" <> Glob.regex(glob, opts) <> "\\z"), subject)

  test "the regular expression it writes" do
    assert Glob.regex("*.ex") == "[^/]*\\.ex"
    assert Glob.regex("a/**/b") == "a/(?:.*/)?b"
    assert Glob.regex("**") == ".*"
    assert Glob.regex("?") == "[^/]"
  end

  test "* and ? stay within one name, ** crosses directories" do
    assert matches?("*.pem", "server.pem")
    refute matches?("*.pem", "certs/server.pem")
    assert matches?("deploy/**/*.key", "deploy/a/b/c.key")
    assert matches?("deploy/**/*.key", "deploy/c.key")
    refute matches?("deploy/**/*.key", "other/c.key")
    assert matches?("src/**", "src/a/b.ex")
    assert matches?("a?c", "abc")
    refute matches?("a?c", "a/c")
  end

  test "everything else is itself" do
    assert matches?("a+b(c).txt", "a+b(c).txt")
    refute matches?("a.txt", "abtxt")
    refute matches?("[ab].txt", "a.txt")
    assert matches?("[ab].txt", "[ab].txt")
  end

  test "slash: false lets * and ? cross a /" do
    assert matches?("github*", "github.create/pr", slash: false)
    assert matches?("a?c", "a/c", slash: false)
  end

  test "braces: true reads {a,b} as either, nested" do
    assert matches?("*.{ts,tsx}", "x.tsx", braces: true)
    assert matches?("{a,{b,c}}.md", "c.md", braces: true)
    refute matches?("*.{ts,tsx}", "x.js", braces: true)
    assert matches?("{a,b}", "{a,b}")
  end

  test "brackets: true reads [a-z] as one of those, and a lone [ as itself" do
    assert matches?("file[0-9].log", "file3.log", brackets: true)
    refute matches?("file[0-9].log", "filex.log", brackets: true)
    assert matches?("a[b", "a[b", brackets: true)
  end
end
