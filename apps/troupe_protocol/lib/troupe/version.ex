defmodule Troupe.Version do
  @moduledoc """
  The one version string, and where every other copy of it has to agree.

  A release is a set of images, a chart that deploys them, and a client that refuses a
  plane it cannot speak to. Each of those carries a version, and until they are one string
  the interesting failure is not a mismatch anybody sees — it is a chart at `0.2.0`
  deploying images built from `0.3.0` and nothing saying so.

  So this is the source. `VERSION` at the repository root holds it, this module reads it at
  compile time, and `Troupe.VersionTest` asserts that every other copy — the umbrella
  and every app's `mix.exs`, the chart's `version` and `appVersion` — says the same thing.
  A copy that drifts fails the build rather than the deploy.

  ## Why a file rather than a module attribute somewhere

  `mix.exs` is read by Mix before any application is compiled, so it cannot call this. A
  file can be read by both — `File.read!` in `mix.exs`, `@external_resource` here — and a
  file is also what a release script, a CI job and a human can all read without starting
  Elixir. The alternative was seven copies and a convention.

  Named `Version` rather than `Release` because `Troupe.Release` is already the release
  *steps* that run between `:assemble` and `:tar` — a different thing that happens to share
  a word.

  ## This is not the protocol version

  `Troupe.Protocol.version/0` is the *wire* major and moves when the contract breaks;
  this moves when a release is cut. A plane at `0.9.0` and one at `1.4.0` may speak the
  same protocol `1`, and a client refuses on the protocol rather than on this.
  """

  @path Path.join([__DIR__, "..", "..", "..", "..", "VERSION"]) |> Path.expand()
  @external_resource @path
  @version (case File.read(@path) do
              {:ok, contents} ->
                String.trim(contents)

              # This app compiled as another project's dependency: a sparse checkout of
              # `apps/troupe_protocol` has no repository root. The consumer says which
              # version it pinned, the same way each `mix.exs` here reads it.
              {:error, _} ->
                System.get_env("TROUPE_VERSION") ||
                  raise "neither #{@path} nor TROUPE_VERSION says which version this is"
            end)

  @doc """
  The release version, as `MAJOR.MINOR.PATCH`.

  Read from `VERSION` at compile time — or from `TROUPE_VERSION` where there is no
  `VERSION`, which is what a consumer outside this umbrella sets — so a build that knows
  its version and a build that does not cannot both exist: a missing answer fails the
  compile rather than defaulting to something plausible.
  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  The major, which is what a client compares.

  The GUI refuses a plane one major ahead of itself, naming both — so this is the number
  that decides whether a client talks to a plane at all, and it is worth being a function
  rather than a string somebody parses at the call site.
  """
  @spec major() :: integer()
  def major, do: @version |> String.split(".") |> hd() |> String.to_integer()
end
