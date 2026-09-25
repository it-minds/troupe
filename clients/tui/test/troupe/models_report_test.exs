defmodule Troupe.ModelsReportTest do
  @moduledoc """
  `troupe models` on a fresh account ends with `troupe config` as the next step. The
  report is the harness's (`Troupe.Config.describe/2`), which names the file instead when
  `troupe-daemon` prints it, because an install may have the daemon without this program;
  this program has the command, so its report says so.

  `async: false`: the keys, the provider variables and the config directory are
  process-global.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Troupe.CLI.Runner

  @vars ~w(ANTHROPIC_API_KEY OPENAI_API_KEY TROUPE_API_KEY TROUPE_AUTH_TOKEN TROUPE_AUTH TROUPE_PROVIDER
           TROUPE_BASE_URL TROUPE_MODEL TROUPE_SMALL_MODEL TROUPE_EXPENSIVE_MODEL TROUPE_CONFIG_HOME
           TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH)

  setup do
    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    base =
      Path.join(System.tmp_dir!(), "troupe-models-report-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "workspace"))
    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
    System.put_env("TROUPE_STATE_HOME", Path.join(base, "state"))
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "no-opencode.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "no-auth.json"))

    on_exit(fn ->
      File.rm_rf!(base)
      Enum.each(previous, &restore_env/1)
    end)

    %{workspace: Path.join(base, "workspace")}
  end

  test "with no key, names `troupe config` as the next step", %{workspace: workspace} do
    out = capture_io(fn -> assert Runner.main(["models", "--workspace", workspace]) == 0 end)

    assert out =~
             "next step: anthropic has no key, so no model can be asked. Run `troupe config` to set up a provider."

    refute out =~ "Write a provider into"
  end

  defp restore_env({var, nil}), do: System.delete_env(var)
  defp restore_env({var, value}), do: System.put_env(var, value)
end
