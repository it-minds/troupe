defmodule Troupe.Plane.GitHub.Policy do
  @moduledoc """
  How far a session's fix loop may go on GitHub, beyond what its token is narrowed to: the
  repositories its team lists, whether it may push to a public one, the paths a push never
  carries, and how many pushes and runs at once.

  Two people decide it, each for what is theirs, and the stricter of the two holds:

  - **The worker profile** (`spec.github`, a platform admin's): `allowPublic` (absent,
    false: pushes and pull requests go to private and internal repositories only),
    `denyPaths` (patterns added to `Troupe.PushPaths.defaults/0`, never in place of them),
    `maxPushes` (pushes per run), `maxRuns` (runs on a repository at once on it) and
    `maxAttempts` (runs on one issue that may end before a sweep leaves it for a person).
  - **The team** (`teams.github`, its own administrators', or in GitOps mode the
    `GitHubApp` resource's): `repositories`, the ones its sessions and triggers may name,
    as `owner/name` or `owner/*`; `max_pushes`, `max_runs` and `max_attempts`, the same
    caps for its runs.

  A team that lists no repository names none. The plane's App bounds them all: a team
  cannot list its way to an owner the App has no installation for.

  What the plane decides here it enforces itself, where it mints tokens and keeps the
  record (`Troupe.Plane.GitHub`): a repository not listed gets no session and no token, and
  a run at its push cap gets a token that cannot push. What only the pod can see, the
  repository's visibility at the moment of a push and the paths in its tree, the pod
  checks against what the plane hands it with the fix loop's token (`for_session/1`).
  """

  alias Troupe.Plane.{Fleet, Repo}
  alias Troupe.Plane.Identity.Team
  alias Troupe.Plane.Sessions.Session

  # A login is letters, digits and single hyphens, at most 39; a repository name is letters,
  # digits, `.`, `_` and `-`, at most 100; `*` is every repository of the owner.
  @owner ~r/\A[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}\z/
  @name ~r/\A(?:\*|[A-Za-z0-9._-]{1,100})\z/

  @max_repositories 500
  @max_cap 1_000

  @profile_keys ~w(allowPublic denyPaths maxPushes maxRuns maxAttempts)
  @team_keys ~w(repositories max_pushes max_runs max_attempts)

  # How many runs on one issue may stop before a sweep leaves it for a person, where neither
  # the profile nor the team says: one. A sweep is the part nobody watches, and an issue
  # whose first run could not fix it is more often one a run cannot fix than one a second
  # run will.
  @default_attempts 1

  @doc "The keys of a profile's `spec.github` this module reads, beside `permissions`."
  @spec profile_keys() :: [String.t()]
  def profile_keys, do: @profile_keys

  @doc "The keys of a team's `github`."
  @spec team_keys() :: [String.t()]
  def team_keys, do: @team_keys

  # -- what is written -------------------------------------------------------------------

  @doc "The problems with a profile's policy keys in `spec.github`, as sentences."
  @spec profile_problems(map()) :: [String.t()]
  def profile_problems(github) when is_map(github) do
    public =
      case Map.fetch(github, "allowPublic") do
        {:ok, value} when not is_boolean(value) ->
          ["github.allowPublic is true or false, not #{inspect(value)}"]

        _absent_or_boolean ->
          []
      end

    public ++
      Troupe.PushPaths.problems(github["denyPaths"]) ++
      cap_problems("github.maxPushes", github["maxPushes"]) ++
      cap_problems("github.maxRuns", github["maxRuns"]) ++
      cap_problems("github.maxAttempts", github["maxAttempts"])
  end

  @doc """
  A team's `github` as `admin.team.update` sends it, read: `repositories`, `max_pushes`,
  `max_runs`, each only where it was sent, laid over what the team has. Answers the whole
  of it as the row keeps it, or the field and the sentence that refuse it.
  """
  @spec read_team(map() | nil, term()) :: {:ok, map()} | {:error, map()}
  def read_team(current, sent) when is_map(sent) do
    sent = Map.new(sent, fn {key, value} -> {to_string(key), value} end)

    case Map.keys(sent) -- @team_keys do
      [] ->
        read_team_keys(current || %{}, sent)

      [key | _] ->
        {:error, %{field: "github.#{key}", reason: "github takes #{Enum.join(@team_keys, ", ")}"}}
    end
  end

  def read_team(_current, nil), do: {:ok, nil}

  def read_team(_current, _sent),
    do:
      {:error,
       %{
         field: "github",
         reason: "github is an object: {repositories, max_pushes, max_runs, max_attempts}"
       }}

  defp read_team_keys(current, sent) do
    Enum.reduce_while(sent, {:ok, current}, fn {key, value}, {:ok, acc} ->
      case team_value(key, value) do
        {:ok, nil} -> {:cont, {:ok, Map.delete(acc, key)}}
        {:ok, read} -> {:cont, {:ok, Map.put(acc, key, read)}}
        {:error, reason} -> {:halt, {:error, %{field: "github.#{key}", reason: reason}}}
      end
    end)
  end

  defp team_value("repositories", nil), do: {:ok, []}

  defp team_value("repositories", list) when is_list(list) do
    cond do
      length(list) > @max_repositories ->
        {:error, "a team lists at most #{@max_repositories} repositories"}

      bad = Enum.find(list, &(not repository_entry?(&1))) ->
        {:error,
         "#{inspect(bad)} is not a repository: owner/name, or owner/* for every repository " <>
           "of the owner"}

      true ->
        {:ok, list |> Enum.map(&String.trim/1) |> Enum.uniq_by(&String.downcase/1)}
    end
  end

  defp team_value("repositories", _other),
    do: {:error, "repositories is a list of owner/name, or owner/*"}

  defp team_value(cap, value) when cap in ["max_pushes", "max_runs", "max_attempts"] do
    case cap_problems(cap, value) do
      [] -> {:ok, value}
      [problem | _] -> {:error, problem}
    end
  end

  defp repository_entry?(entry) when is_binary(entry) do
    case String.split(String.trim(entry), "/") do
      [owner, name] ->
        Regex.match?(@owner, owner) and Regex.match?(@name, name) and name not in [".", ".."]

      _ ->
        false
    end
  end

  defp repository_entry?(_entry), do: false

  defp cap_problems(_field, nil), do: []

  defp cap_problems(_field, value) when is_integer(value) and value >= 1 and value <= @max_cap,
    do: []

  defp cap_problems(field, value),
    do: ["#{field} is a whole number from 1 to #{@max_cap}, not #{inspect(value)}"]

  # -- a team's repositories ---------------------------------------------------------------

  @doc """
  Whether `team` lists `owner/name` for its sessions: `:ok`, or why not. A team that lists
  none names none, and a session with no team names none.
  """
  @spec listed(Team.t() | nil, String.t(), String.t()) :: :ok | {:error, term()}
  def listed(nil, owner, name), do: {:error, {:no_team, "#{owner}/#{name}"}}

  def listed(%Team{} = team, owner, name) do
    listed = get_in(team.github || %{}, ["repositories"]) || []
    full = String.downcase("#{owner}/#{name}")
    every = String.downcase("#{owner}/*")

    if Enum.any?(listed, &(String.downcase(&1) in [full, every])),
      do: :ok,
      else: {:error, {:not_listed, team.name, "#{owner}/#{name}", listed}}
  end

  @doc "A session's team, read again: what it lists may have changed since the session began."
  @spec team_of(Session.t()) :: Team.t() | nil
  def team_of(%Session{team_id: nil}), do: nil
  def team_of(%Session{team_id: id}), do: Repo.get(Team, id)

  # -- what the pod is handed ---------------------------------------------------------------

  @doc """
  What a session's pod checks before a push or a pull request, handed with the fix loop's
  token: `allow_public`, the whole `deny_paths` list, and `max_pushes` (or `nil`).
  """
  @spec for_session(Session.t()) :: map()
  def for_session(%Session{} = session) do
    github = profile_github(session.profile)

    %{
      "allow_public" => github["allowPublic"] == true,
      "deny_paths" => Troupe.PushPaths.effective(github["denyPaths"]),
      "max_pushes" => max_pushes(session)
    }
  end

  @doc "How many pushes a session's run may make, the lower of its profile's and its team's."
  @spec max_pushes(Session.t()) :: pos_integer() | nil
  def max_pushes(%Session{} = session) do
    lowest([
      profile_github(session.profile)["maxPushes"],
      get_in((team_of(session) || %Team{}).github || %{}, ["max_pushes"])
    ])
  end

  @doc "Whether a session's run has made as many pushes as it may."
  @spec pushes_spent?(Session.t(), map() | nil) :: boolean()
  def pushes_spent?(%Session{} = session, record) do
    case max_pushes(session) do
      nil -> false
      cap -> ((record || %{})["pushes"] || 0) >= cap
    end
  end

  # -- runs at once --------------------------------------------------------------------------

  @doc """
  Why a trigger's run on a repository may not start now, or `nil`: as many runs on a
  repository are live on the run's profile as `maxRuns` allows, or on its team as
  `max_runs` does. `live` counts the live runs on a repository other than the one asking,
  narrowed by `profile:` or `team_id:`.
  """
  @spec over_runs_cap(String.t() | nil, String.t() | nil, (keyword() -> non_neg_integer())) ::
          String.t() | nil
  def over_runs_cap(profile, team_id, live) do
    profile_cap = profile_github(profile)["maxRuns"]

    team_cap =
      case team_id && Repo.get(Team, team_id) do
        %Team{github: %{"max_runs" => cap}} when is_integer(cap) -> cap
        _ -> nil
      end

    cond do
      profile_cap && live.(profile: profile) >= profile_cap ->
        "the worker profile #{profile} allows #{profile_cap} " <>
          "#{runs(profile_cap)} on a repository at once (github.maxRuns)"

      team_cap && live.(team_id: team_id) >= team_cap ->
        "the team allows #{team_cap} #{runs(team_cap)} on a repository at once (github.max_runs)"

      true ->
        nil
    end
  end

  defp runs(1), do: "run"
  defp runs(_n), do: "runs"

  # -- attempts on one issue -------------------------------------------------------------------

  @doc """
  How many runs on one issue may end before a sweep leaves the issue for a person: the
  lower of the profile's `maxAttempts` and the team's `max_attempts`, and one where neither
  says. A person asking again, with the label, the command or the console's "fix this", is
  not held to it, and starts the count again.
  """
  @spec max_attempts(String.t() | nil, String.t() | nil) :: pos_integer()
  def max_attempts(profile, team_id) do
    team = (team_id && Repo.get(Team, team_id)) || %Team{}

    lowest([profile_github(profile)["maxAttempts"], get_in(team.github || %{}, ["max_attempts"])]) ||
      @default_attempts
  end

  # -- small things ---------------------------------------------------------------------------

  defp profile_github(nil), do: %{}

  defp profile_github(profile) do
    case Fleet.get_profile(profile) do
      %{spec: %{"github" => %{} = github}} -> github
      _ -> %{}
    end
  end

  defp lowest(values) do
    case Enum.filter(values, &is_integer/1) do
      [] -> nil
      caps -> Enum.min(caps)
    end
  end
end
