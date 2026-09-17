defmodule Troupe.Plane.Build do
  @moduledoc """
  Which build of this plane is answering.

  The footer has always carried `plane 0.2.0`, which is the version in `mix.exs`. That
  number is right and useless for the question people actually ask, which is *is the thing
  I just deployed the thing that is running*: it changes when somebody edits a file, not
  when an image is built, so two deploys a week apart report the same string.

  So a build carries an identity of its own — the commit it was built from, and when — and
  the page shows it. It is read from the environment rather than compiled in, because a
  release is built once and run in several places, and a value baked at compile time would
  be a value the image cannot be asked about afterwards.

  ## What it is allowed to say

  A commit hash and a timestamp. Not a branch name, not a dirty-tree marker, not the
  builder's hostname: this renders on a page anybody who can reach the plane can read, and
  the useful half is the half that identifies the artifact. A short hash somebody can paste
  into `git show` is the whole job.

  `dev` where nothing set it, which is what a laptop and a `mix phx.server` are — and is
  honest, because a tree somebody is editing does not have a build identity.
  """

  @unknown "dev"

  @doc """
  The commit this build came from, short, or `"dev"`.

  Short because the footer is a footer. Seven characters is what `git` itself abbreviates
  to and what a person recognises; anybody who needs the whole thing has the deploy that
  set it.
  """
  @spec commit() :: String.t()
  def commit do
    case env("TROUPE_BUILD_COMMIT") do
      nil -> @unknown
      sha -> String.slice(sha, 0, 7)
    end
  end

  @doc "When the image was built, as it was given, or `nil`."
  @spec built_at() :: String.t() | nil
  def built_at, do: env("TROUPE_BUILD_TIME")

  @doc "The release version from `mix.exs`, which is the other half of the answer."
  @spec version() :: String.t()
  def version, do: to_string(Application.spec(:troupe_plane, :vsn) || @unknown)

  @doc """
  Whether this build knows what it is.

  A page can then say so rather than printing `dev` beside a version and leaving somebody
  to work out whether that is a value or a failure.
  """
  @spec identified?() :: boolean()
  def identified?, do: commit() != @unknown

  @doc """
  One line for a footer: the version, the commit, and the build date where there is one.

  Assembled here rather than in the page because `/.well-known/troupe` answers the same
  question for a script, and two places formatting it differently is how a deploy check
  ends up disagreeing with a browser.
  """
  @spec label() :: String.t()
  def label do
    [version(), commit_part(), date_part()]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc "The same facts as data, for `/.well-known/troupe` and the admin surface."
  @spec to_json() :: map()
  def to_json do
    %{"version" => version(), "commit" => commit(), "built_at" => built_at()}
  end

  defp commit_part do
    if identified?(), do: commit(), else: nil
  end

  # The date and not the time. A footer that changed every time somebody looked at the
  # clock would be a footer people stop reading, and *which day* is what answers "is this
  # the deploy from this morning".
  defp date_part do
    case built_at() do
      nil -> nil
      stamp -> stamp |> String.split("T") |> List.first()
    end
  end

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _unset -> nil
    end
  end
end
