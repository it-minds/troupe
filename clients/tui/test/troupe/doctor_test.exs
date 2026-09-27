defmodule Troupe.DoctorCLITest do
  @moduledoc """
  `troupe doctor` (TUI Decision 123): the harness's checks, printed one per line with
  `troupe config` as the next step, and the exit status. The suite's config directory
  is scratch (test_helper.exs); this test writes its own user file there and puts it
  back. `async: false`: the file is shared.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Troupe.CLI.Doctor

  setup do
    user = Troupe.Config.user_path()
    before = File.read!(user)
    on_exit(fn -> File.write!(user, before) end)
    %{user: user}
  end

  test "with no provider it fails the provider line, naming troupe config, and exits 1", %{
    user: user
  } do
    File.write!(user, "version: 1\n")

    out = capture_io(fn -> assert Doctor.run(File.cwd!()) == 1 end)

    assert out =~
             ~r/^FAIL  provider +anthropic has no key, so no model can be asked; run `troupe config`$/m

    assert out =~ ~r/^ok    plane +none configured$/m
  end

  test "with the fake provider every line passes and it exits 0", %{user: user} do
    File.write!(user, "version: 1\nprovider: fake\n")

    out = capture_io(fn -> assert Doctor.run(File.cwd!()) == 0 end)
    assert out =~ ~r/^ok    provider +fake, claude-sonnet-5, no key needed$/m
    assert out =~ ~r/^ok    key +the fake provider asks nobody$/m
    assert out =~ ~r/^ok    key storage +/m
    refute out =~ "FAIL"
  end
end
