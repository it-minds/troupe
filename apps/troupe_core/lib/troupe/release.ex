defmodule Troupe.Release do
  @moduledoc """
  Release steps that run between `:assemble` and `Burrito.wrap/1`.
  """

  @doc """
  Fail the build if a Linux target bundled a glibc NIF.

  Burrito's Linux wrapper carries a musl ERTS, so the ExRatatui NIF in the payload
  must be the musl variant — a glibc `.so` cannot load there and the shipped binary
  would die at NIF load on every end-user machine, which is exactly the class of
  problem that only shows up after distribution.

  ExRatatui ships `verify_linux_nif/1` for this, but it keys off `BURRITO_TARGET`
  being literally `"linux"`; Troupe's targets are `linux_x86_64` and `linux_aarch64`
  because the alias doubles as the artifact suffix. This does the same byte scan
  against the same NIF path, for any Linux target.
  """
  @spec verify_linux_nif(Mix.Release.t()) :: Mix.Release.t()
  def verify_linux_nif(%Mix.Release{} = release) do
    if linux_target?() do
      # Called by name because `ex_ratatui` is the TUI's dependency, not the core's:
      # this runs at release time, when every app's beams are on the path anyway.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      {_otp_app, relative_path} = apply(ExRatatui.Native, :load_from, [])

      release.path
      |> Path.join("lib/ex_ratatui-*/#{relative_path}.so")
      |> Path.wildcard()
      |> case do
        [] ->
          Mix.raise("""
          No ex_ratatui NIF found in the assembled release at
          #{release.path}/lib/ex_ratatui-*/#{relative_path}.so

          The release layout changed, and this check would otherwise pass while
          verifying nothing.
          """)

        paths ->
          Enum.each(paths, &verify_musl!/1)
      end
    end

    release
  end

  @doc """
  Build every reaper target into `priv/` before the payload is packed.

  `mix compile.reaper` builds only the host triple during development; a release has
  to carry all five, because Burrito bundles `priv/` wholesale and the binary must be
  able to run `shell` wherever it lands.
  """
  @spec build_reapers(Mix.Release.t()) :: Mix.Release.t()
  def build_reapers(%Mix.Release{} = release) do
    System.put_env("TROUPE_REAPER_TARGETS", "all")
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

  defp linux_target? do
    case System.get_env("BURRITO_TARGET") do
      nil -> false
      target -> String.starts_with?(target, "linux")
    end
  end

  defp verify_musl!(so_path) do
    bytes = File.read!(so_path)

    if String.contains?(bytes, "libc.so.6") or String.contains?(bytes, "GLIBC_") do
      Mix.raise("""
      #{Path.relative_to_cwd(so_path)} is a glibc NIF, but Burrito's Linux wrapper
      runs a musl runtime — the wrapped binary would fail at NIF load on every
      end-user machine.

      Rebuild with the musl NIF:

          TARGET_ABI=musl BURRITO_TARGET=#{System.get_env("BURRITO_TARGET")} MIX_ENV=prod mix release --overwrite

      TARGET_ABI only chooses between precompiled NIFs, so it has no effect on a
      locally built crate: unset EX_RATATUI_BUILD and any :force_build
      rustler_precompiled config first, and wipe _build/prod/lib/ex_ratatui if a
      stale glibc artifact is still sitting there.
      """)
    end
  end
end
