defmodule Mix.Tasks.Compile.TroupeVersionTest do
  @moduledoc """
  A build after `VERSION` changes says the new version (issue #380, Decision 768).

  Two real builds of a project that reads its version from a file the way every `mix.exs`
  here reads `VERSION`, each in a `mix` of its own: the first with the file at 1.0.0, the
  second after it says 1.1.0 and nothing else has changed. That is a checkout that built
  the previous release being built again after the bump, which is what
  `scripts/install-local.ps1` does.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @elixir System.find_executable("elixir") || "elixir"

  test "with :troupe_version, the second build writes the new version into the .app",
       %{tmp_dir: dir} do
    project!(dir, [:troupe_version])

    assert build!(dir, "1.0.0") == "1.0.0"
    assert build!(dir, "1.1.0") == "1.1.0"
  end

  # Why the compiler exists. Should Mix come to rewrite the `.app` on its own, this fails,
  # and `:troupe_version` can go from every `mix.exs`.
  test "without it, Mix keeps the version of the first build", %{tmp_dir: dir} do
    project!(dir, [])

    assert build!(dir, "1.0.0") == "1.0.0"
    assert build!(dir, "1.1.0") == "1.0.0"
  end

  defp project!(dir, compilers) do
    File.write!(Path.join(dir, "mix.exs"), """
    defmodule VersionBump.MixProject do
      use Mix.Project

      def project do
        [
          app: :version_bump,
          version: File.read!("VERSION") |> String.trim(),
          compilers: Mix.compilers() ++ #{inspect(compilers)},
          # The compiler is on the code path `-pa` gives, as no dependency's: Mix would
          # otherwise prune that path before the compilers run.
          prune_code_paths: false
        ]
      end
    end
    """)
  end

  # The `vsn` the build left in the `.app`.
  defp build!(dir, version) do
    File.write!(Path.join(dir, "VERSION"), version <> "\n")
    ebin = Path.dirname(:code.which(Mix.Tasks.Compile.TroupeVersion))

    {out, status} =
      System.cmd(@elixir, ["-pa", ebin, "-S", "mix", "compile"],
        cd: dir,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    assert status == 0, out

    {:ok, [{:application, :version_bump, properties}]} =
      :file.consult(Path.join(dir, "_build/dev/lib/version_bump/ebin/version_bump.app"))

    to_string(properties[:vsn])
  end
end
