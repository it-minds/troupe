defmodule Troupe.Plane.GitHub.Issues do
  @moduledoc """
  Runs the plane starts on a repository's issues by reading them itself rather than from a
  delivery: a trigger's **sweep** on its schedule, and a person's **"fix this"** from the
  console.

  ## What both are held to

  A trigger on a repository (`GitHub.Issue`); its team listing the repository; the App
  installed for the repository's owner; and the repository private or internal unless the
  trigger's profile allows public ones (`spec.github.allowPublic`). Those are what a
  session naming the repository, and a push to it, are held to already; asked here first,
  so that a run which could never push is never started. The issue is read with a token of
  the plane's own, narrowed to the repository and to reading (`GitHub.reader/5`), audited,
  and it reaches the session as a delivery's issue does: fenced and marked as data
  (`GitHub.Issue.prompt/2`). Each start is `Triggers.fire/5`, so the trigger's concurrency,
  the profile's and the team's caps of runs on a repository, and the budget hold as they do
  for any run.

  ## A sweep

  At each minute its `sweep` cron names, the open issues with the trigger's label, or those
  its `query` finds, oldest first and at most 50 of them, and one run for each that is not
  already being fixed and has not been tried as often as it may be:

  - **Being fixed** is a run on the issue in flight (one a cap would count: still to start,
    working, or waiting on a person), or an open pull request that a run on the issue
    recorded, which is the App's own: a draft for a person to review is the issue being
    fixed, by them now.
  - **Tried** is a run the sweep started on the issue that has ended: three red CI rounds
    or its cap of pushes closed it, its budget, turns or wall clock ran out, it failed, or
    it finished and its pull request was closed. Counted since a person last asked for a
    run on it, with its label, its command or "fix this"; a person's own runs are not held
    to the cap. The cap is `GitHub.Policy.max_attempts/2`, one where nobody set it.

  A sweep stops at the first run a cap skips or the plane refuses: the rest of the issues
  wait for its next minute, rather than one skipped run being recorded for each.

  ## "Fix this"

  One issue, by its number or its link, which must be on the trigger's repository: an
  open issue, not a pull request. Fired `manual`, by the person, with the key of the
  person, the issue and the minute, so a second click is the run the first made.
  """

  alias Troupe.Plane.{Fleet, GitHub, Principals, Repo, Triggers}
  alias Troupe.Plane.GitHub.{Issue, Policy}
  alias Troupe.Plane.Identity.Team
  alias Troupe.Plane.Triggers.{Run, Trigger}
  alias Troupe.Protocol.Error

  require Logger

  # The most issues one sweep looks at, and so the most runs it could start.
  @sweep_limit 50

  # How many open pull requests a sweep reads to tell which issues have one.
  @pulls_limit 100

  # Sources of a run a person asked for: a label or a command GitHub delivered, and the
  # console's hand.
  @asked ~w(webhook manual)

  # -- a sweep ---------------------------------------------------------------------------

  @doc """
  Sweep a trigger's repository for a minute: one run for each open issue it finds that is
  not being fixed and not tried as often as it may be, until a cap or a refusal stops it.
  Answers what became of each issue it looked at, or why it could not look.
  """
  @spec sweep(Trigger.t(), DateTime.t()) :: {:ok, [map()]} | {:error, String.t()}
  def sweep(%Trigger{} = trigger, %DateTime{} = due) do
    permissions = %{"issues" => "read", "pull_requests" => "read"}
    at = DateTime.to_iso8601(due)
    audit = %{"trigger" => trigger.name, "for" => "sweep at #{at}"}

    with {:ok, owner, name} <- placed(trigger),
         {:ok, reader} <-
           GitHub.reader(owner, name, permissions, audit, principal_subject(trigger)),
         :ok <- private_or_allowed(reader, trigger),
         {:ok, issues} <- candidates(reader, trigger.source),
         {:ok, open} <- open_pulls(reader) do
      cap = Policy.max_attempts(trigger.profile, trigger.team_id)
      {:ok, start_each(issues, trigger, reader.repository, open, cap, at)}
    else
      {:error, reason} -> {:error, GitHub.explain(reason)}
    end
  end

  defp candidates(reader, %{"query" => query}) when is_binary(query),
    do: reader.search.(query, @sweep_limit)

  defp candidates(reader, %{"label" => label}) when is_binary(label) do
    params = [state: "open", labels: label, sort: "created", direction: "asc"]

    case reader.get.("/issues", params ++ [per_page: @sweep_limit]) do
      # GitHub lists a pull request among a repository's issues; a run starts from an issue.
      {:ok, issues} when is_list(issues) ->
        {:ok, Enum.reject(issues, &is_map(&1["pull_request"]))}

      {:ok, _other} ->
        {:error, "GitHub's answer for the repository's issues was not a list"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp candidates(_reader, _source),
    do: {:error, "a sweep looks for the trigger's label or its query, and it has neither"}

  defp open_pulls(reader) do
    case reader.get.("/pulls", state: "open", per_page: @pulls_limit) do
      {:ok, pulls} when is_list(pulls) -> {:ok, MapSet.new(pulls, & &1["number"])}
      {:ok, _other} -> {:error, "GitHub's answer for the open pull requests was not a list"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_each(issues, trigger, full, open, cap, at) do
    issues
    |> Enum.filter(&is_integer(&1["number"]))
    |> Enum.reduce_while([], fn issue, done ->
      {go_on, outcome} = consider(issue, trigger, full, open, cap, at)
      {go_on, [outcome | done]}
    end)
    |> Enum.reverse()
  end

  # One issue: left, with why, or a run started on it, and whether the sweep goes on.
  defp consider(issue, trigger, full, open, cap, at) do
    case why_not(Triggers.issue_runs(full, issue["number"]), open, cap) do
      nil -> start(trigger, issue, full, at)
      why -> {:cont, %{"issue" => issue["number"], "left" => why}}
    end
  end

  defp start(trigger, issue, full, at) do
    number = issue["number"]
    event = Issue.found("sweep", issue, full, nil)
    key = "sweep:#{trigger.id}:#{at}:#{number}"

    case Triggers.fire(trigger, "schedule", key, event, "scheduler") do
      {:ok, %{run: %Run{state: "skipped"} = run}} ->
        {:halt, %{"issue" => number, "run" => run.id, "skipped" => run.reason}}

      {:ok, fired} ->
        {:cont, %{"issue" => number, "run" => fired.run.id, "session_id" => fired.run.session_id}}

      {:error, %Error{} = error} ->
        Logger.warning(
          "troupe plane: the sweep of #{trigger.name} could not start a run on #{full}##{number}: " <>
            "#{error.message} #{inspect(error.data)}"
        )

        {:halt, %{"issue" => number, "refused" => error.message}}
    end
  end

  @doc """
  Why a sweep leaves an issue alone, from the runs on it and the repository's open pull
  requests, or `nil` where it may start one: a run going, an open pull request a run
  recorded, or as many ended runs since a person last asked as the cap allows.
  """
  @spec why_not([{Run.t(), map() | nil}], MapSet.t(), pos_integer()) :: String.t() | nil
  def why_not(runs, open, cap) do
    cond do
      Enum.any?(runs, fn {run, session} -> Triggers.live?(run, session) end) ->
        "a run on it is going"

      number = Enum.find_value(runs, &open_pull_request(&1, open)) ->
        "it has an open pull request, ##{number}, that a run on it opened"

      (tried = attempts(runs)) >= cap ->
        "#{tried} #{if tried == 1, do: "run", else: "runs"} a sweep started on it ended " <>
          "without a fix, as many as it may (github.maxAttempts): a person asks again with " <>
          "its label, its command or the console's fix this"

      true ->
        nil
    end
  end

  defp open_pull_request({_run, %{github: %{"pull_request" => %{"number" => number}}}}, open)
       when is_integer(number),
       do: if(MapSet.member?(open, number), do: number)

  defp open_pull_request(_run_and_session, _open), do: nil

  # The sweep's own runs on the issue that ended, newest first, until the one a person
  # asked for: a person asking starts the count again.
  defp attempts(runs) do
    runs
    |> Enum.take_while(fn {run, _session} -> run.source not in @asked end)
    |> Enum.count(fn {run, session} ->
      run.source == "schedule" and not is_nil(run.session_id) and
        not Triggers.live?(run, session)
    end)
  end

  # -- "fix this" ------------------------------------------------------------------------

  @doc """
  Start one run of a trigger on one issue of its repository, for a person: `issue` its
  number, or its link on the App's host. Read from GitHub first: an open issue, not a pull
  request. Answers what `Triggers.fire/5` does, or a refusal that says why.
  """
  @spec fix(Trigger.t(), term(), String.t()) :: {:ok, Triggers.fired()} | {:error, Error.t()}
  def fix(%Trigger{} = trigger, issue, by) when is_binary(by) do
    audit = %{"trigger" => trigger.name, "for" => "fix this, by #{by}"}

    with :ok <- enabled(trigger),
         {:ok, owner, name} <- placed(trigger),
         {:ok, number} <- number(issue, owner, name),
         {:ok, reader} <- GitHub.reader(owner, name, %{"issues" => "read"}, audit, by),
         :ok <- private_or_allowed(reader, trigger),
         {:ok, found} <- open_issue(reader, number) do
      minute = DateTime.utc_now() |> DateTime.truncate(:second) |> Map.put(:second, 0)
      key = "fix:#{trigger.id}:#{number}:#{by}:#{DateTime.to_iso8601(minute)}"
      event = Issue.found("fix", found, reader.repository, by)
      Triggers.fire(trigger, "manual", key, event, by)
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, refused(reason)}
    end
  end

  defp enabled(%Trigger{enabled: true}), do: :ok

  defp enabled(%Trigger{} = trigger),
    do:
      {:error,
       Error.new(:forbidden, %{
         trigger: trigger.name,
         reason: "#{trigger.name} is paused: resume it first"
       })}

  defp number(number, _owner, _name) when is_integer(number) and number > 0, do: {:ok, number}

  defp number(text, owner, name) when is_binary(text) do
    text = String.trim(text)

    case Integer.parse(String.trim_leading(text, "#")) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> from_link(text, owner, name)
    end
  end

  defp number(_other, _owner, _name),
    do: {:error, "an issue is its number, or its link on GitHub"}

  # A link on the App's own host to an issue of the trigger's repository, and no other.
  defp from_link(text, owner, name) do
    with %URI{host: host, path: path} when is_binary(host) and is_binary(path) <- URI.parse(text),
         true <- String.downcase(host) == String.downcase(GitHub.git_host() || ""),
         [link_owner, link_name, "issues", digits] <- String.split(path, "/", trim: true),
         {number, ""} when number > 0 <- Integer.parse(digits) do
      if String.downcase("#{link_owner}/#{link_name}") == String.downcase("#{owner}/#{name}"),
        do: {:ok, number},
        else:
          {:error,
           "that issue is on #{link_owner}/#{link_name}, and this trigger works on #{owner}/#{name}"}
    else
      _ ->
        {:error,
         "an issue is its number, or its link, such as https://#{GitHub.git_host() || "github.com"}" <>
           "/#{owner}/#{name}/issues/7"}
    end
  end

  defp open_issue(reader, number) do
    case reader.get.("/issues/#{number}", []) do
      {:ok, %{"pull_request" => %{}}} ->
        {:error, "##{number} is a pull request, and a run starts from an issue"}

      {:ok, %{"state" => "closed"}} ->
        {:error, "##{number} is closed"}

      {:ok, %{"number" => ^number} = issue} ->
        {:ok, issue}

      {:ok, _other} ->
        {:error, "GitHub's answer for ##{number} was not an issue"}

      {:error, {:github, 404, _message, owner, name}} ->
        {:error, "#{owner}/#{name} has no issue ##{number}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refused(reason),
    do: Error.new(:invalid_params, %{field: "issue", reason: GitHub.explain(reason)})

  # -- what both ask -----------------------------------------------------------------------

  # The trigger's repository, which its team must list, as for any session that names it.
  defp placed(%Trigger{} = trigger) do
    case Issue.repository(trigger.source) do
      {owner, name} ->
        team = trigger.team_id && Repo.get(Team, trigger.team_id)

        with :ok <- Policy.listed(team, owner, name), do: {:ok, owner, name}

      nil ->
        {:error, "#{trigger.name} is not a trigger on a GitHub repository"}
    end
  end

  # A push to a public repository is refused unless the profile allows it, so a run on one
  # is not started either. Asked of GitHub now, as the pod asks at every push.
  defp private_or_allowed(reader, %Trigger{profile: profile}) do
    case profile && Fleet.get_profile(profile) do
      %{spec: %{"github" => %{"allowPublic" => true}}} -> :ok
      _private_only -> private(reader, profile)
    end
  end

  defp private(reader, profile) do
    case reader.get.("", []) do
      {:ok, %{} = repository} ->
        if private?(repository),
          do: :ok,
          else:
            {:error,
             "#{reader.repository} is public, and the worker profile #{profile} does not " <>
               "allow public repositories (github.allowPublic), so a run on it could not push"}

      {:ok, _other} ->
        {:error, "GitHub's answer for #{reader.repository} was not a repository"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private or internal as GitHub reports it; anything else, an answer that says neither
  # among them, is public.
  defp private?(%{"visibility" => visibility}) when visibility in ["private", "internal"],
    do: true

  defp private?(%{"visibility" => _other}), do: false
  defp private?(%{"private" => true}), do: true
  defp private?(_repository), do: false

  defp principal_subject(%Trigger{principal_id: id}) do
    case Principals.fetch(id) do
      %{subject: subject} -> subject
      nil -> nil
    end
  end
end
