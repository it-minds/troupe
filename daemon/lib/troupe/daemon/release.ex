defmodule Troupe.Daemon.Release do
  @moduledoc """
  The two release steps between `:assemble` and `:tar`.

  **The reaper.** Every OS process the harness starts runs under the `reaper` helper, a
  small Zig program `troupe_core` looks up in its `priv/reaper/<triple>/`. `mix
  compile.reaper` builds it for the build host while the dependency compiles, but only when
  `zig` was on the `PATH` at that moment and only into `deps/`, which `:assemble` may or
  may not have copied. This builds it again, for the host's triple, straight into the
  assembled release — and fails without `zig`, on purpose: a daemon whose every `shell`
  call answers "reaper helper not built" is exactly the failure this repository exists to
  stop shipping. A release is built on the platform it runs on, so the host's triple is the
  right one.

  **The wrapper.** `bin/troupe-daemon` (and `bin/troupe-daemon.cmd`) is the command line a
  person and a client use: `run` is the release's `start`, everything else is `eval` into
  `Troupe.Daemon.CLI.eval/1`. It resolves the release root from its own location, so the
  installer can put a symlink to it on the `PATH`.
  """

  alias Mix.Tasks.Compile.Reaper

  @spec reaper(Mix.Release.t()) :: Mix.Release.t()
  def reaper(%Mix.Release{} = release) do
    triple = Reaper.host_triple()
    source = source!()
    vsn = release.applications |> Map.fetch!(:troupe_core) |> Keyword.fetch!(:vsn)
    out_dir = Path.join([release.path, "lib", "troupe_core-#{vsn}", "priv", "reaper", triple])
    out = Path.join(out_dir, exe_name(triple))

    File.mkdir_p!(out_dir)
    Mix.shell().info("reaper: building #{triple} into the release")

    args = [
      "build-exe",
      source,
      "-target",
      triple,
      "-O",
      "ReleaseSafe",
      "-lc",
      "-fstrip",
      "--name",
      "reaper",
      "-femit-bin=" <> out
    ]

    case System.cmd("zig", args, stderr_to_stdout: true) do
      {_out, 0} ->
        File.chmod!(out, 0o755)
        out_dir |> Path.join("*") |> Path.wildcard() |> Enum.each(&drop_artifact/1)
        release

      {output, code} ->
        Mix.raise("reaper: zig build failed for #{triple} (exit #{code})\n#{output}")
    end
  end

  @spec wrapper(Mix.Release.t()) :: Mix.Release.t()
  def wrapper(%Mix.Release{} = release) do
    sh = Path.join([release.path, "bin", "troupe-daemon"])
    File.write!(sh, wrapper_sh())
    File.chmod!(sh, 0o755)
    File.write!(Path.join([release.path, "bin", "troupe-daemon.cmd"]), wrapper_cmd())
    release
  end

  # The dependency's checkout, whichever shape Mix gave the sparse clone.
  defp source! do
    base = Mix.Project.deps_paths() |> Map.fetch!(:troupe_core)

    Enum.find(
      [
        Path.join([base, "native", "reaper", "reaper.zig"]),
        Path.join([base, "apps", "troupe_core", "native", "reaper", "reaper.zig"])
      ],
      &File.exists?/1
    ) || Mix.raise("reaper: no reaper.zig under #{base}")
  end

  defp exe_name("x86_64-windows"), do: "reaper.exe"
  defp exe_name(_triple), do: "reaper"

  # zig build-exe drops a .pdb / .o alongside the binary on some targets.
  defp drop_artifact(path) do
    if Path.extname(path) in [".pdb", ".o", ".obj", ".lib"], do: File.rm(path)
  end

  # `run` checks `status` first so that a second `run` says where the running daemon is
  # and exits 0 rather than failing to bind. Everything else is `eval` with the arguments
  # after `--`, which the release script hands to `System.argv/0` untouched — no quoting
  # of anything into an Elixir literal.
  defp wrapper_sh do
    ~S"""
    #!/bin/sh
    # troupe-daemon: the local Troupe harness. `run` serves; everything else asks.
    set -eu
    self="$0"
    while [ -L "$self" ]; do
      target=$(readlink "$self")
      case "$target" in /*) self="$target" ;; *) self="$(dirname "$self")/$target" ;; esac
    done
    root="$(cd "$(dirname "$self")/.." && pwd)"
    rel="$root/bin/troupe_daemon"

    case "${1:-run}" in
      run)
        if "$rel" eval 'Troupe.Daemon.CLI.eval(System.argv())' -- status >/dev/null 2>&1; then
          "$rel" eval 'Troupe.Daemon.CLI.eval(System.argv())' -- status
          exit 0
        fi
        exec "$rel" start
        ;;
      *)
        exec "$rel" eval 'Troupe.Daemon.CLI.eval(System.argv())' -- "$@"
        ;;
    esac
    """
  end

  # Untested here: this repository is built and checked on Linux runners and a WSL
  # laptop. The Windows release job runs it.
  defp wrapper_cmd do
    ~S"""
    @echo off
    rem troupe-daemon: the local Troupe harness. `run` serves; everything else asks.
    setlocal
    set "root=%~dp0.."
    set "rel=%root%\bin\troupe_daemon.bat"
    set "cmd=%~1"
    if "%cmd%"=="" set "cmd=run"
    if "%cmd%"=="run" (
      call "%rel%" eval "Troupe.Daemon.CLI.eval(System.argv())" -- status >nul 2>&1
      if not errorlevel 1 (
        call "%rel%" eval "Troupe.Daemon.CLI.eval(System.argv())" -- status
        exit /b 0
      )
      call "%rel%" start
      exit /b %errorlevel%
    )
    call "%rel%" eval "Troupe.Daemon.CLI.eval(System.argv())" -- %*
    exit /b %errorlevel%
    """
  end
end
