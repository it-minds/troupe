defmodule Troupe.ReleaseTest do
  use ExUnit.Case, async: true

  @repository Path.expand("../../../..", __DIR__)
  @licence_files ~w(LICENSE NOTICE THIRD-PARTY-NOTICES.txt)

  describe "licences/1" do
    test "copies the repository's licence files into the release, and names them for its tarball" do
      path = Path.join(System.tmp_dir!(), "troupe-release-#{System.unique_integer([:positive])}")
      File.mkdir_p!(path)
      on_exit(fn -> File.rm_rf!(path) end)

      release = Troupe.Release.licences(%Mix.Release{path: path, overlays: ["already/there"]})

      for file <- @licence_files do
        assert File.read!(Path.join(path, file)) == File.read!(Path.join(@repository, file))
      end

      assert release.overlays == ["already/there" | @licence_files]
    end
  end
end
