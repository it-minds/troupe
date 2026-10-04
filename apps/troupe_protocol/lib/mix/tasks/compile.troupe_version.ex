defmodule Mix.Tasks.Compile.TroupeVersion do
  @moduledoc """
  Writes an app's `.app` again when the version in it is not the project's.

  Every `mix.exs` here takes its version from `VERSION` (Decision 668), but Mix's `:app`
  compiler writes the `.app` again only when `mix.exs`, the config or the compile directory
  changed since it last did, and a new `VERSION` is none of those. So a checkout that built
  the previous release kept its `vsn` after the bump: `Application.spec/2` answered the old
  version, the TUI that `scripts/install-local.ps1` installed said so in `troupe --version`,
  and `Troupe.VersionTest` failed until somebody removed the `.app` files (Decision 768).

  Every project that reads `VERSION` lists it after `:app`, as
  `compilers: Mix.compilers() ++ [:troupe_version]`. It reads the `.app` that `:app` left,
  and when its `vsn` is not the project's version it has `:app` write it again; otherwise it
  is a no-op. It lives in `troupe_protocol` because every other project here depends on that
  app, which is compiled before them, and `troupe_protocol` itself reaches it because it
  runs after `:elixir`.
  """

  use Mix.Task.Compiler

  @recursive true

  @impl Mix.Task.Compiler
  def run(_argv) do
    config = Mix.Project.config()

    # The umbrella root has no app, and so no `.app`, when this is run there by hand.
    if config[:app] && stale?(config) do
      Mix.Task.rerun("compile.app", ["--force"])
    else
      {:noop, []}
    end
  end

  # A missing or unreadable `.app` is `:app`'s business, not this one's.
  defp stale?(config) do
    app_file = Path.join(Mix.Project.compile_path(config), "#{config[:app]}.app")

    case :file.consult(app_file) do
      {:ok, [{:application, _app, properties}]} -> to_string(properties[:vsn]) != config[:version]
      _ -> false
    end
  end
end
