defmodule Troupe.Plane.Web.Live.Overview do
  @moduledoc """
  Fleet health, sessions and spend, on one page — and what needs doing, first.

  The first page an operator opens when something is wrong, so it answers the question
  they actually have, which is not "what are the numbers" but "what should I look at".
  Four metrics, then a list of everything that is not healthy, worst first. When that list
  is empty it says so in a sentence rather than disappearing, because an empty region and
  a region that has not loaded look identical.

  Refreshed on a timer rather than on a push: every number here is a summary, and a
  summary that moved the instant any one session did would flicker. The list is sorted
  when it is built and not re-sorted between refreshes for the same reason the design
  gives — a table that reorders while it is being read is a table nobody can read.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin
  alias Troupe.Plane.Web.Live.Status

  @refresh_ms 2_000

  # Where a team stops being comfortable and starts being worth mentioning. Not a setting:
  # it decides what a list says, not what the platform does.
  @near_budget 0.8

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)
    {:ok, load(socket)}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    case Admin.overview(socket.assigns.actor) do
      {:ok, overview} ->
        assign(socket, overview: overview, attention: attention(overview), error: nil)

      {:error, error} ->
        assign(socket, overview: nil, attention: [], error: error.message)
    end
  end

  # -- what needs doing --------------------------------------------------------

  # Everything that is not healthy, as one list. Built here rather than by each panel
  # because the point of the page is that an operator does not have to visit four screens
  # to find out whether anything is wrong.
  defp attention(overview) do
    (pods(overview) ++ profiles(overview) ++ budgets(overview))
    |> Enum.sort_by(&Status.severity(&1.state))
  end

  defp pods(overview) do
    for profile <- overview.profiles,
        pod <- profile.pods,
        state = Status.from_worker(pod),
        state != :healthy do
      %{
        state: state,
        what: pod_sentence(state, pod, profile),
        where: "/admin/workers/#{profile.name}",
        action: "look at #{profile.name}"
      }
    end
  end

  defp pod_sentence(:unknown, pod, profile) do
    "#{pod.pod} on #{profile.name} has never reported. It may be starting, or it may not be there."
  end

  defp pod_sentence(:broken, pod, profile) do
    "#{pod.pod} on #{profile.name} reported that it is not healthy."
  end

  defp pod_sentence(:draining, pod, profile) do
    "#{pod.pod} on #{profile.name} is draining: #{pod.active_sessions} session(s) still on it."
  end

  defp pod_sentence(state, pod, profile) do
    "#{pod.pod} on #{profile.name} is #{Status.describe(state).word |> String.downcase()}."
  end

  # A profile with fewer pods than it asked for is degraded whatever each pod says about
  # itself: the ones that are missing cannot report.
  defp profiles(overview) do
    for profile <- overview.profiles,
        length(profile.pods) < profile.replicas do
      %{
        state: :degraded,
        what:
          "#{profile.name} asked for #{profile.replicas} pod(s) and has #{length(profile.pods)}.",
        where: "/admin/workers/#{profile.name}",
        action: "look at #{profile.name}"
      }
    end
  end

  # Over budget is not one of the twelve states, and inventing a thirteenth is the thing
  # the design forbids. It is reported as what it does: a team over its ceiling cannot
  # start a session, which is broken from that team's side, and one approaching it is
  # degraded.
  defp budgets(overview) do
    for team <- overview.teams,
        team.budget_micros > 0,
        state = budget_state(team),
        state != :healthy do
      %{
        state: state,
        what: budget_sentence(state, team),
        where: "/admin/teams",
        action: "look at #{team.name}"
      }
    end
  end

  defp budget_state(team) do
    cond do
      team.spent_micros + team.reserved_micros >= team.budget_micros -> :broken
      fraction(team) >= @near_budget -> :degraded
      true -> :healthy
    end
  end

  # Only a `monthly` ceiling turns over, and it says when: the ledger counts the calendar
  # month in UTC, so "the period" is the 1st wherever the reader is. Any other is lifted
  # only by raising it, so its sentences name no period and promise no new one.
  defp budget_sentence(:broken, %{budget_period: "monthly"} = team) do
    "#{team.name} is at its monthly ceiling. New sessions are refused until it is raised or the period turns over, on the 1st of the month (UTC)."
  end

  defp budget_sentence(:broken, team) do
    "#{team.name} is at its ceiling, which never turns over. New sessions are refused until it is raised."
  end

  defp budget_sentence(_degraded, %{budget_period: "monthly"} = team) do
    "#{team.name} has spent #{percent(team)} of its monthly budget."
  end

  defp budget_sentence(_degraded, team) do
    "#{team.name} has spent #{percent(team)} of its budget."
  end

  defp fraction(%{budget_micros: 0}), do: 0.0

  defp fraction(team) do
    (team.spent_micros + team.reserved_micros) / team.budget_micros
  end

  defp percent(team), do: "#{round(fraction(team) * 100)}%"

  # -- the four numbers --------------------------------------------------------

  defp pods_healthy(overview) do
    all = Enum.flat_map(overview.profiles, & &1.pods)
    {Enum.count(all, &(Status.from_worker(&1) == :healthy)), length(all)}
  end

  defp spent(overview), do: Enum.sum(Enum.map(overview.teams, & &1.spent_micros))
  defp committed(overview), do: Enum.sum(Enum.map(overview.teams, & &1.budget_micros))

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} breakglass={@breakglass} page={:overview}>
      <h1>Overview</h1>

      <p :if={@error} class="banner banner--breakglass" role="alert">{@error}</p>

      <div :if={@overview}>
        <div class="metrics">
          <.metric label="Active sessions" value={to_string(@overview.sessions.active)}>
            <:context>
              {@overview.sessions.dormant} dormant, {@overview.sessions.read_only} read-only
            </:context>
          </.metric>

          <.metric label="Pods" value={pods_value(@overview)}>
            <:context>healthy, across {length(@overview.profiles)} profile(s)</:context>
          </.metric>

          <.metric label="Spent" value={money(spent(@overview))}>
            <:context>
              against {money(committed(@overview))} committed across {length(@overview.teams)} team(s)
            </:context>
          </.metric>

          <.metric label="Needs attention" value={to_string(length(@attention))}>
            <:context>
              {if @attention == [], do: "nothing is unhealthy", else: "worst first, below"}
            </:context>
          </.metric>
        </div>

        <h2>Needs attention</h2>

        <p :if={@attention == []} class="empty">
          Nothing is unhealthy, over budget or waiting. Nothing needs doing.
        </p>

        <ul :if={@attention != []} class="attention">
          <li :for={item <- @attention} class={"attention__item attention__item--#{item.state}"}>
            <Status.cell state={item.state} />
            <span class="attention__what">{item.what}</span>
            <a href={item.where} class="button">{item.action}</a>
          </li>
        </ul>

        <h2>Profiles</h2>
        <div class="scroller">
          <table>
            <caption>What is running, and how full it is.</caption>
            <thead>
              <tr>
                <th scope="col">profile</th>
                <th scope="col">status</th>
                <th scope="col" class="num">pods</th>
                <th scope="col" class="num">capacity</th>
                <th scope="col" class="num">in use</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={profile <- @overview.profiles} class={row_class(profile)}>
                <th scope="row">
                  <.link navigate={"/admin/workers/#{profile.name}"}>{profile.name}</.link>
                </th>
                <td><Status.cell state={profile_state(profile)} /></td>
                <td class="num">{length(profile.pods)} / {profile.replicas}</td>
                <td class="num">{profile.capacity}</td>
                <td class="num">{profile.active_sessions}</td>
              </tr>
              <tr :if={@overview.profiles == []}>
                <td colspan="5" class="empty">No profiles you can see.</td>
              </tr>
            </tbody>
          </table>
        </div>

        <h2>Spend</h2>
        <div class="scroller">
          <table>
            <caption>What each team has spent against what it committed.</caption>
            <thead>
              <tr>
                <th scope="col">team</th>
                <th scope="col">against budget</th>
                <th scope="col" class="num">spent</th>
                <th scope="col" class="num">reserved</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={team <- @overview.teams}>
                <th scope="row">{team.name}</th>
                <td><.budget team={team} /></td>
                <td class="num"><.amount micros={team.spent_micros} /></td>
                <td class="num"><.amount micros={team.reserved_micros} /></td>
              </tr>
              <tr :if={@overview.teams == []}>
                <td colspan="4" class="empty">No teams you can see.</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.shell>
    """
  end

  defp pods_value(overview) do
    {healthy, total} = pods_healthy(overview)
    "#{healthy} / #{total}"
  end

  defp profile_state(profile) do
    cond do
      length(profile.pods) < profile.replicas -> :degraded
      profile.pods == [] -> :unknown
      true -> profile.pods |> Enum.map(&Status.from_worker/1) |> Enum.min_by(&Status.severity/1)
    end
  end

  defp row_class(profile), do: Status.row_class(profile_state(profile))
end
