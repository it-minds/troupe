defmodule Troupe.Config.WriteKeyTest do
  @moduledoc """
  `Troupe.Config.write_key/3`, the door a budget answer for the workspace goes through
  (Decision 699): one key set in a project's file, the rest of the file kept, the file
  before the write kept beside it, a missing file made, and a broken one left alone.
  """

  use ExUnit.Case, async: true

  alias Troupe.Config

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-write-key-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    %{path: Path.join([base, ".troupe", "config.yaml"])}
  end

  defp read(path) do
    {:ok, map} = YamlElixir.read_from_file(path)
    map
  end

  test "sets the key and keeps the rest of the file, with the file before it beside it", %{
    path: path
  } do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "# the team's settings\ndefault_agent: review\nmax_turns: 40\n")

    assert {:ok, ^path} = Config.write_key(path, ["max_turns"], 65)

    assert read(path) == %{"default_agent" => "review", "max_turns" => 65}
    assert File.read!(path <> ".previous") =~ "# the team's settings"
  end

  test "changes the key's own line and nothing else, comments included", %{path: path} do
    File.mkdir_p!(Path.dirname(path))

    text = """
    # the team's settings

    default_agent: review   # reviews first
    max_turns: 40           # raised once already
    wall_clock_ms: 900000
    """

    File.write!(path, text)

    assert {:ok, ^path} = Config.write_key(path, ["max_turns"], 65)
    assert File.read!(path) == String.replace(text, "max_turns: 40 ", "max_turns: 65 ")

    # A key the file does not have is added after its last key, and nothing else moves.
    assert {:ok, ^path} = Config.write_key(path, ["max_depth"], 3)
    assert File.read!(path) == String.replace(text, "max_turns: 40 ", "max_turns: 65 ") <> "max_depth: 3\n"
    assert File.read!(path <> ".previous") =~ "max_turns: 65"
  end

  test "makes a file that is not there", %{path: path} do
    assert {:ok, ^path} = Config.write_key(path, ["wall_clock_ms"], 2_700_000)
    assert read(path) == %{"version" => 1, "wall_clock_ms" => 2_700_000}
  end

  test "leaves a file that is not YAML alone and says why", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "max_turns: [\n")

    assert {:error, reason} = Config.write_key(path, ["max_turns"], 65)
    assert reason =~ "not valid YAML"
    assert File.read!(path) == "max_turns: [\n"
  end
end
