defmodule Troupe.Session.UnknownProviderTest do
  @moduledoc """
  A provider name nobody implements is a config mistake with an answer, not a crash.

  `provider: litellm` in a laptop's `config.yaml` — the name of the gateway rather than
  the wire it speaks — reached the root agent, where `{:ok, adapter} = adapter(name)`
  raised. The client saw a `badmatch` wrapped in two layers of `failed_to_start_child`
  and no clue what to change.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "start_session refuses before the tree starts", %{tmp_dir: workspace} do
    assert {:error, {:unknown_provider, :litellm}} =
             Troupe.start_session(
               workspace: workspace,
               config_overrides: [provider: "litellm", state_dir: Path.join(workspace, ".state")]
             )
  end

  test "a provider that exists still starts", %{tmp_dir: workspace} do
    assert {:ok, session} =
             Troupe.start_session(
               workspace: workspace,
               config_overrides: [provider: "fake", state_dir: Path.join(workspace, ".state")]
             )

    Troupe.stop_session(session.id)
  end
end
