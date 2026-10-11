defmodule Troupe.UpdateCLITest do
  @moduledoc """
  `troupe update` (#66, Decision 865): the command line. What it does is
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

  test "troupe update refuses what it cannot mean" do
    assert {:error, message} = CLI.parse(["update", "--rollback", "--version", "1.0.0"])
    assert message =~ "--rollback"
    assert {:error, _} = CLI.parse(["update", "--version"])
    assert {:error, _} = CLI.parse(["update", "now"])
    assert {:error, _} = CLI.parse(["update", "--bogus"])
  end

  test "the help names troupe update" do
    assert CLI.usage() =~ "troupe update [--check] [--version X]"
    assert CLI.usage() =~ "troupe update --rollback"
  end
end
