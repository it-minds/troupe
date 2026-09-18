defmodule Troupe.VersionTest do
  @moduledoc """
  One version string, and every copy of it made to agree by a test rather than by care.

  A release is a set of images, a chart that deploys them and a client that refuses a plane
  it cannot speak to. Each carries a version, and the interesting failure is not a mismatch
  somebody notices — it is a chart at `0.2.0` deploying images built from `0.3.0`, with
  nothing anywhere saying so.

  So every copy is enumerated here and compared against `VERSION`. A new `mix.exs`, a new
  chart, a new manifest that hard-codes a number: each of them fails this until it reads the
  file the others read.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  defp read!(path), do: @root |> Path.join(path) |> File.read!()

  defp version, do: "VERSION" |> read!() |> String.trim()

  describe "the release version" do
    test "is a plain semantic version, on one line" do
      assert version() =~ ~r/^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/,
             "VERSION is #{inspect(version())}, which is not MAJOR.MINOR.PATCH"

      # A trailing newline and nothing else. A file read by `mix.exs`, by a CI job and by a
      # shell script is a file where a stray second line becomes somebody's version string.
      assert read!("VERSION") == version() <> "\n"
    end

    test "is what `Troupe.Version` compiled with" do
      assert Troupe.Version.version() == version()

      assert Troupe.Version.major() ==
               version() |> String.split(".") |> hd() |> String.to_integer()
    end

    test "is what the umbrella and every app declare" do
      # Read from the compiled projects rather than by parsing `mix.exs`, because what
      # matters is the version an app actually has — a file that reads `VERSION` and a file
      # that hard-codes the same string are not the same thing next month, and only one of
      # them is what `Application.spec/2` answers.
      for app <- ~w(troupe_protocol troupe_core troupe_gateway troupe_worker
                    troupe_plane troupe_operator troupe_a2a)a do
        assert to_string(Application.spec(app, :vsn)) == version(),
               "#{app} is #{Application.spec(app, :vsn)} and VERSION is #{version()}"
      end
    end

    test "is what the chart deploys, in both of the places a chart says it" do
      chart = read!("charts/troupe/Chart.yaml")

      assert chart =~ ~r/^version:\s*#{Regex.escape(version())}\s*$/m,
             "the chart's own version is not #{version()}"

      # `appVersion` is what the chart claims it deploys; `version` is the chart's. They
      # move together here because one repository builds both, and a chart whose two
      # numbers disagree is a chart nobody can read the release from.
      assert chart =~ ~r/^appVersion:\s*"?#{Regex.escape(version())}"?\s*$/m,
             "the chart's appVersion is not #{version()}"
    end
  end

  describe "the protocol version" do
    test "is not this one, and is a major on its own" do
      # `Troupe.Protocol.version/0` moves when the wire contract breaks; the release
      # version moves when a release is cut. A client refuses a plane on the protocol, not
      # on this — and a test that let them be the same string would make the next protocol
      # break look like a patch release.
      assert Troupe.Protocol.version() =~ ~r/^\d+$/
      refute Troupe.Protocol.version() == version()
    end
  end
end
