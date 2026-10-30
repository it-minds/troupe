defmodule Troupe.UpdateCLITest do
  @moduledoc """
  `troupe update` (#66): the command line. What it does is
  `Troupe.Update`'s, tested in `troupe_core`; this is that the TUI takes it.
  """

  use ExUnit.Case, async: true

  alias Troupe.CLI

  test "troupe update takes --check, --version X and --rollback" do
    assert {:ok, %{mode: :update, check: true, rollback: false, update_version: nil}} =
             CLI.parse(["update", "--check"])

    assert {:ok, %{mode: :update, check: false, rollback: false, update_version: nil}} =
             CLI.parse(["update"])

    assert {:ok, %{mode: :update, update_version: "0.13.0-beta"}} =
             CLI.parse(["update", "--version", "0.13.0-beta"])

    # A `v` is how a tag spells it, and the release's own number is without one.
    assert {:ok, %{mode: :update, update_version: "0.13.0"}} =
             CLI.parse(["update", "--version", "v0.13.0"])

    assert {:ok, %{mode: :update, check: true, update_version: "0.13.0"}} =
             CLI.parse(["update", "--check", "--version", "0.13.0"])

    assert {:ok, %{mode: :update, rollback: true}} = CLI.parse(["update", "--rollback"])

    # `--version` alone is still the program's own.
    assert {:ok, %{mode: :version}} = CLI.parse(["--version"])
  end

  test "troupe update chooses --recommended unless told --latest" do
    assert {:ok, %{mode: :update, update_pick: :recommended}} = CLI.parse(["update"])

    assert {:ok, %{mode: :update, update_pick: :recommended}} =
             CLI.parse(["update", "--recommended"])

    assert {:ok, %{mode: :update, update_pick: :latest, check: false}} =
             CLI.parse(["update", "--latest"])

    assert {:ok, %{mode: :update, update_pick: :latest, check: true}} =
             CLI.parse(["update", "--check", "--latest"])
  end

  test "--latest goes with neither --recommended, --version nor --rollback" do
    assert {:error, both} = CLI.parse(["update", "--latest", "--recommended"])

    assert both ==
             "troupe update takes --recommended or --latest, not both: the version the plane " <>
               "recommends, or the newest release that supports it"

    assert {:error, named} = CLI.parse(["update", "--latest", "--version", "0.36.0-beta"])

    assert named ==
             "troupe update --version 0.36.0-beta names the release; --latest and " <>
               "--recommended choose one, so neither goes with it"

    assert {:error, rollback} = CLI.parse(["update", "--rollback", "--latest"])
    assert rollback =~ "--rollback takes nothing else"
    assert {:error, unknown} = CLI.parse(["update", "--newest"])
    assert unknown =~ "--recommended, --latest, --version X and --rollback"
  end

  test "troupe update refuses what it cannot mean" do
    assert {:error, message} = CLI.parse(["update", "--rollback", "--version", "1.0.0"])
    assert message =~ "--rollback"
    assert {:error, _} = CLI.parse(["update", "--version"])
    assert {:error, _} = CLI.parse(["update", "now"])
    assert {:error, _} = CLI.parse(["update", "--bogus"])
  end

  test "the help names troupe update" do
    assert CLI.usage() =~ "troupe update [--check] [--recommended | --latest | --version X]"
    assert CLI.usage() =~ "troupe update --rollback"
  end
end
