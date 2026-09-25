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

  test "start_session refuses before the tree starts, and says what to write", %{tmp_dir: workspace} do
    assert {:error, %Troupe.Config.Error{} = error} =
             Troupe.start_session(
               workspace: workspace,
               config_overrides: [provider: "litellm", state_dir: Path.join(workspace, ".state")]
             )

    message = Exception.message(error)
    assert message =~ "provider is set to \"litellm\"; it must be one of anthropic, openai, fake"
    assert message =~ "is `openai` with its base_url"
  end

  test "a file naming one is refused the same way, naming the file", %{tmp_dir: workspace} do
    user = Path.join(workspace, "user.yaml")
    File.write!(user, "provider: litellm\n")

    assert {:error, %Troupe.Config.Error{} = error} = Troupe.Config.resolve(workspace, [], user_path: user)
    assert Exception.message(error) =~ "#{user}:1: provider must be one of anthropic, openai, fake, not \"litellm\""
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
