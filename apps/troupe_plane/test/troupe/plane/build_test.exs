defmodule Troupe.Plane.BuildTest do
  @moduledoc """
  Which build is answering, which is not the same question as which version.

  `plane 0.2.0` is the version in `mix.exs`. It changes when somebody edits a file, not
  when an image is built, so two deploys a week apart report the same string — and the
  question people actually ask is *is the thing I just deployed the thing that is
  running*. These tests are about the identity that answers that one.
  """

  use ExUnit.Case, async: false

  alias Troupe.Plane.Build

  setup do
    previous = {System.get_env("TROUPE_BUILD_COMMIT"), System.get_env("TROUPE_BUILD_TIME")}

    on_exit(fn ->
      {commit, time} = previous

      if commit,
        do: System.put_env("TROUPE_BUILD_COMMIT", commit),
        else: System.delete_env("TROUPE_BUILD_COMMIT")

      if time,
        do: System.put_env("TROUPE_BUILD_TIME", time),
        else: System.delete_env("TROUPE_BUILD_TIME")
    end)

    System.delete_env("TROUPE_BUILD_COMMIT")
    System.delete_env("TROUPE_BUILD_TIME")
    :ok
  end

  describe "a build nobody stamped" do
    test "says dev, and says it does not know" do
      # A tree somebody is editing has no build identity, and `dev` is the honest answer
      # rather than a version dressed up as one.
      assert Build.commit() == "dev"
      refute Build.identified?()
      assert is_nil(Build.built_at())
    end

    test "and the label is the version alone" do
      assert Build.label() == Build.version()
      refute Build.label() =~ "dev ·"
    end
  end

  describe "a stamped build" do
    test "shows the short commit and the day, not the whole timestamp" do
      System.put_env("TROUPE_BUILD_COMMIT", "8351b07f3c2a1d4e5f6a7b8c9d0e1f2a3b4c5d6e")
      System.put_env("TROUPE_BUILD_TIME", "2026-09-17T14:32:10Z")

      # Seven characters is what git abbreviates to and what a person recognises; anybody
      # who needs the whole hash has the deploy that set it.
      assert Build.commit() == "8351b07"
      assert Build.identified?()

      label = Build.label()
      assert label =~ Build.version()
      assert label =~ "8351b07"

      # The day, not the clock: a footer that changed every time somebody looked would be
      # a footer people stop reading, and *which day* is what answers the question.
      assert label =~ "2026-09-17"
      refute label =~ "14:32"
    end

    test "carries the same facts to a script as to a reader" do
      System.put_env("TROUPE_BUILD_COMMIT", "abc1234def")
      System.put_env("TROUPE_BUILD_TIME", "2026-09-17T14:32:10Z")

      # `/.well-known/troupe` and the footer read one function, because a deploy check that
      # disagreed with the page would be worse than either on its own.
      assert Build.to_json() == %{
               "version" => Build.version(),
               "commit" => "abc1234",
               "built_at" => "2026-09-17T14:32:10Z"
             }
    end

    test "an empty variable is unset rather than a value" do
      # A build arg nobody passed arrives as `""`, and an empty string shown as a commit
      # would read as a build with no identity pretending to have one.
      System.put_env("TROUPE_BUILD_COMMIT", "")
      System.put_env("TROUPE_BUILD_TIME", "")

      assert Build.commit() == "dev"
      assert is_nil(Build.built_at())
    end
  end

  describe "what it will not say" do
    test "no branch, no hostname, no dirty marker" do
      System.put_env("TROUPE_BUILD_COMMIT", "8351b07")

      # This renders on a page anybody who can reach the plane can read. The useful half
      # is the half that identifies the artifact; the rest is somebody's laptop.
      label = Build.label()
      refute label =~ "main"
      refute label =~ "dirty"

      # Three parts at most: the version, the commit, the day. Anything else somebody
      # wanted to add would show up here as a fourth.
      assert label |> String.split(" · ") |> length() <= 3
    end
  end
end
