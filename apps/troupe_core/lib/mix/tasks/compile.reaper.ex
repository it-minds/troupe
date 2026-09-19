defmodule Mix.Tasks.Compile.Reaper do
  @moduledoc """
  Cross-compiles the `reaper` helper into this app's `priv/reaper/`.

  The Zig source lives in this app, at `apps/troupe_core/native/reaper/`, beside the
  module that loads the binaries at runtime — and so that a checkout of this app alone
  (the daemon binary is built from it in another repository) carries everything the
  `shell` tool needs.

  `reaper` is the process-tree supervisor every shell command runs under, and it is
  built with Zig because one toolchain cross-compiles every triple this project has a
  use for. The worker's release carries the Linux ones; the rest exist so the suite can
  run `shell` on a developer's own machine, which is the only place they are ever built.

  Without `zig` on `PATH` this task is a no-op with a warning: a checkout that only
  needs `mix test` against already-built binaries, or a machine that never runs
  `shell`, should not be blocked on a Zig install.

  `TROUPE_REAPER_TARGETS` is a comma-separated list of triples, or `all`; the default
  builds only the host triple, which is what a dev loop needs. `Troupe.Release` sets it
  to the Linux triples when it packs a release, because a pod runs nothing else.
  """

  use Mix.Task.Compiler

  @recursive true

  @targets %{
    "x86_64-linux-musl" => [os: :linux, cpu: :x86_64],
    "aarch64-linux-musl" => [os: :linux, cpu: :aarch64],
    "x86_64-macos" => [os: :darwin, cpu: :x86_64],
    "aarch64-macos" => [os: :darwin, cpu: :aarch64],
    "x86_64-windows" => [os: :windows, cpu: :x86_64]
  }

  @doc false
  def targets, do: Map.keys(@targets)

  @impl Mix.Task.Compiler
  def run(_argv) do
    source = source_path()

    cond do
      # `@recursive` is how this reaches `troupe_core` when `mix compile.reaper` is run
      # from the umbrella root — and it also reaches every *other* app, each of which
      # would then cross-compile all five targets into a `priv/reaper` nothing reads.
      # The binaries belong to `troupe_core`; that cost forty-odd redundant Zig builds
      # on every image build and put six extra copies in every release.
      Mix.Project.config()[:app] != :troupe_core ->
        {:noop, []}

      not File.exists?(source) ->
        {:noop, []}

      is_nil(System.find_executable("zig")) ->
        Mix.shell().info([
          :yellow,
          "reaper: zig not found on PATH, skipping native build. ",
          "The `shell` tool will not run until it is built.",
          :reset
        ])

        {:noop, []}

      true ->
        build(source)
    end
  end

  # The app's own `native/`, whether the app is compiled inside the umbrella or as a
  # dependency of another project; the umbrella-root spelling is kept for a checkout
  # that predates the move.
  defp source_path do
    Enum.find(
      [
        Path.join(["native", "reaper", "reaper.zig"]),
        Path.join(["..", "..", "native", "reaper", "reaper.zig"])
      ],
      &File.exists?/1
    ) || Path.join(["native", "reaper", "reaper.zig"])
  end

  @impl Mix.Task.Compiler
  def clean do
    File.rm_rf!(Path.join("priv", "reaper"))
    :ok
  end

  defp build(source) do
    wanted =
      case System.get_env("TROUPE_REAPER_TARGETS") do
        "all" -> Map.keys(@targets)
        nil -> [host_triple()]
        list -> String.split(list, ",", trim: true)
      end

    src_mtime = File.stat!(source).mtime

    results = Enum.map(wanted, &build_target(&1, source, src_mtime))

    if Enum.any?(results, &(&1 == :error)), do: {:error, []}, else: {:ok, []}
  end

  defp build_target(triple, source, src_mtime) do
    unless Map.has_key?(@targets, triple) do
      Mix.raise(
        "reaper: unknown target #{inspect(triple)}, expected one of #{inspect(targets())}"
      )
    end

    out_dir = Path.join(["priv", "reaper", triple])
    out = Path.join(out_dir, exe_name(triple))

    if fresh?(out, src_mtime) do
      :ok
    else
      File.mkdir_p!(out_dir)
      Mix.shell().info("reaper: building #{triple}")

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
          cleanup_artifacts(out_dir)
          :ok

        {out, code} ->
          Mix.shell().error("reaper: zig build failed for #{triple} (exit #{code})\n#{out}")
          :error
      end
    end
  end

  defp fresh?(out, src_mtime) do
    case File.stat(out) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime >= src_mtime
      _ -> false
    end
  end

  # zig build-exe drops a .pdb / .o alongside the binary on some targets.
  defp cleanup_artifacts(dir) do
    dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      if Path.extname(path) in [".pdb", ".o", ".obj", ".lib"], do: File.rm(path)
    end)
  end

  defp exe_name("x86_64-windows"), do: "reaper.exe"
  defp exe_name(_), do: "reaper"

  @doc """
  The Zig target triple for the host, used both here and by the runtime lookup in
  `Troupe.Reaper`.
  """
  def host_triple do
    arch =
      case :erlang.system_info(:system_architecture) |> List.to_string() do
        "aarch64" <> _ -> "aarch64"
        "arm64" <> _ -> "aarch64"
        _ -> "x86_64"
      end

    case :os.type() do
      {:unix, :darwin} -> arch <> "-macos"
      {:unix, _} -> arch <> "-linux-musl"
      {:win32, _} -> "x86_64-windows"
    end
  end
end
