defmodule Troupe.Release do
  @moduledoc """
  Release steps that run between `:assemble` and `:tar`.
  """

  # A server release runs in a container on a node pool, and both node pools anyone
  # deploys this to are Linux. Cross-compiling the other three triples took a Zig build
  # each for a binary no pod could ever execute.
  @release_reaper_targets "x86_64-linux-musl,aarch64-linux-musl"

  @doc """
  Build the reaper for each Linux target before the release is packed.

  `mix compile.reaper` builds only the host triple during development, which is what a
  dev loop wants. A release has to carry the binaries for the architectures it will be
  run on, because `priv/` is packed once and a pod cannot build anything.
  """
  @spec build_reapers(Mix.Release.t()) :: Mix.Release.t()
  def build_reapers(%Mix.Release{} = release) do
    System.put_env("TROUPE_REAPER_TARGETS", @release_reaper_targets)
    Mix.Task.rerun("compile.reaper")

    # `:assemble` has already copied priv/ into the release, so the freshly built
    # binaries have to be copied across too.
    source = Path.join(Mix.Project.build_path(), "lib/troupe_core/priv/reaper")
    destination = Path.join(release.path, "lib/troupe_core-#{release.version}/priv/reaper")

    if File.dir?(source) do
      File.mkdir_p!(destination)
      File.cp_r!(source, destination)
    end

    release
  end
end
