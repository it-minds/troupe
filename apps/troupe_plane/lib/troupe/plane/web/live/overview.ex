defmodule Troupe.Plane.Web.Live.Overview do
  @moduledoc """
  The page at `/admin`: fleet health, sessions and spend, read-only, and the way to the
  console.

  Everything an administrator does is done in the console at `/console`, an app of its
  own. This page is what is left of the LiveView console that came before it, and it is
  kept for one day: the day the console cannot be used, because the identity provider it
  signs in through cannot let anybody in. The break-glass door (`/admin/breakglass`) opens
  this page without the provider, and what somebody needs there is to see what the plane
  is doing and to undo the setting that locked everybody out.

  So it reads, and it repairs nothing but sign-in. Four metrics, then everything that is
  not healthy, worst first, then each profile and each team's spend; and, in a break-glass
  session, sign-in as the plane holds it, the identity check, and a way to put the sign-in
  settings and the two settings that decide who administers back to what the deployment
  says. Each of those is a reset, never a value typed here: the deployment is the floor
  every setting is laddered on, and the worst a reset can do is go back to it.

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

  # The settings that decide who administers this platform: the two that, wrong, lock
  # every administrator out of the console.
  @administration ~w(platform_admin_group groups_claim)

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)
    # The router says where the console is; without one this plane is administered with
    # `troupe admin`, over `/rpc` or the admin MCP tools.
    {:ok,
     socket
     |> assign(console_url: session["console_url"], resetting: nil, repaired: nil)
     |> load()
     |> load_sign_in()}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl Phoenix.LiveView
  def handle_event("confirm-reset", %{"what" => what}, socket) do
    {:noreply, assign(socket, resetting: what)}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, resetting: nil)}

  def handle_event("reset", %{"what" => "sign-in"}, socket) do
    socket.assigns.actor
    |> Admin.provider_reset()
    |> repaired(socket, "Sign-in is back to what the deployment says.")
  end

  def handle_event("reset", %{"what" => key}, socket) when key in @administration do
    socket.assigns.actor
    |> Admin.setting_reset(key)
    |> repaired(socket, "#{key} is back to what the deployment says.")
  end

  defp repaired({:ok, _answer}, socket, said) do
    {:noreply, socket |> assign(resetting: nil, repaired: said) |> load_sign_in()}
  end

  defp repaired({:error, error}, socket, _said) do
    {:noreply, assign(socket, resetting: nil, repaired: describe(error))}
  end

  defp load(socket) do
    case Admin.overview(socket.assigns.actor) do
      {:ok, overview} ->
        assign(socket,
          overview: overview,
          attention: attention(overview, socket.assigns),
          error: nil
        )

      {:error, error} ->
        assign(socket, overview: nil, attention: [], error: error.message)
    end
  end

  # Only in a break-glass session: what sign-in is, and whether it works, read through the
  # same functions the console reads it with.
  defp load_sign_in(%{assigns: %{breakglass: true, actor: actor}} = socket) do
    with {:ok, provider} <- Admin.provider_get(actor),
         {:ok, settings} <- Admin.settings_list(actor),
         {:ok, check} <- Admin.identity_check(actor) do
      administration = Enum.filter(settings.settings, &(&1.key in @administration))
      assign(socket, provider: provider, administration: administration, check: check)
    else
      {:error, error} ->
        assign(socket, provider: nil, administration: [], check: nil, repaired: describe(error))
    end
  end

  defp load_sign_in(socket), do: assign(socket, provider: nil, administration: [], check: nil)

  defp describe(%{message: message, data: %{reason: reason}}), do: "#{message}: #{reason}"
  defp describe(%{message: message}), do: message

  # -- what needs doing --------------------------------------------------------

  # Everything that is not healthy, as one list. Built here rather than by each panel
  # because the point of the page is that an operator does not have to visit four screens
  # to find out whether anything is wrong.
  defp attention(overview, assigns) do
    (pods(overview, assigns) ++ profiles(overview, assigns) ++ budgets(overview, assigns))
    |> Enum.sort_by(&Status.severity(&1.state))
  end

  defp pods(overview, assigns) do
    for profile <- overview.profiles,
        pod <- profile.pods,
        state = Status.from_worker(pod),
        state != :healthy do
      %{
        state: state,
        what: pod_sentence(state, pod, profile),
        where: in_console(assigns, "pods"),
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
  defp profiles(overview, assigns) do
    for profile <- overview.profiles,
        length(profile.pods) < profile.replicas do
      %{
        state: :degraded,
        what:
          "#{profile.name} asked for #{profile.replicas} pod(s) and has #{length(profile.pods)}.",
        where: in_console(assigns, "pods"),
        action: "look at #{profile.name}"
      }
    end
  end

  # Over budget is not one of the twelve states, and inventing a thirteenth is the thing
  # the design forbids. It is reported as what it does: a team over its ceiling cannot
  # start a session, which is broken from that team's side, and one approaching it is
  # degraded.
  defp budgets(overview, assigns) do
    for team <- overview.teams,
        team.budget_micros > 0,
        state = budget_state(team),
        state != :healthy do
      %{
        state: state,
        what: budget_sentence(state, team),
        where: in_console(assigns, "teams/#{team.name}/limits"),
        action: "look at #{team.name}"
      }
    end
  end

  # Where the console shows a thing, or nothing on a plane without one: this page links
  # out and does not do it here.
  defp in_console(%{console_url: nil}, _place), do: nil
  defp in_console(%{console_url: url}, place), do: "#{url}#/#{place}"

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

  # -- sign-in, in a break-glass session ----------------------------------------

  defp stored?(provider), do: Enum.any?(provider.settings, &(&1.source == :stored))

  defp shown(%{secret: true, set: true}), do: "set · never shown"
  defp shown(%{secret: true}), do: "not set"
  defp shown(%{value: nil}), do: "not set"
  defp shown(%{value: list}) when is_list(list), do: Enum.join(list, " ")
  defp shown(%{value: value}), do: to_string(value)

  defp source_note(%{source: :stored}), do: "changed in the console"
  defp source_note(%{source: :deployed}), do: "from the deployment"
  defp source_note(%{source: :unset}), do: "not set"

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} breakglass={@breakglass} page={:overview} console_url={@console_url}>
      <h1>Overview</h1>

      <p :if={@console_url} class="notice" id="new-console">
        Administering this platform is done in the console, at
        <a href={@console_url}>{@console_url}</a>. This page only reads: it is the way in on
        the day the console cannot be used, through the break-glass door, and what it can
        change is sign-in, back to what the deployment says.
      </p>

      <p :if={is_nil(@console_url)} class="notice" id="no-console">
        This plane is deployed without the console, so it is administered with
        <code>troupe admin</code>, over <code>/rpc</code> or with the admin MCP tools at
        <code>/mcp</code>. This page only reads.
      </p>

      <p :if={@error} class="banner banner--breakglass" role="alert">{@error}</p>

      <section :if={@breakglass} class="panel" id="repair">
        <h2>Sign-in, from behind the glass</h2>
        <p class="hint">
          What the console signs in through, as this plane holds it, and whether it works.
          Each setting can go back to what the deployment says, which is the floor every
          setting stands on: nothing is typed here, so nothing new can be saved wrong here.
          A value the deployment itself has wrong is changed in the deployment and rolled.
        </p>

        <p :if={@repaired} class="banner" role="status" id="repaired">{@repaired}</p>

        <ul :if={@check} class="checks" id="identity-checks">
          <li :for={check <- @check.checks} class={if check.ok, do: "checks__ok", else: "checks__bad"}>
            <span class="checks__name">{check.name}</span>
            <span class="checks__detail">{check.detail}</span>
          </li>
        </ul>

        <div :if={@provider} class="setting" id="sign-in-settings">
          <h3>Where people sign in</h3>
          <.title_block>
            <:field :for={setting <- @provider.settings} label={setting.key}>
              <code>{shown(setting)}</code> <span class="micro">{source_note(setting)}</span>
            </:field>
          </.title_block>
          <.reset :if={stored?(@provider)} what="sign-in" resetting={@resetting}>
            Every sign-in value changed in the console goes, and the deployment's are read again.
          </.reset>
        </div>

        <div :for={setting <- @administration} class="setting" id={"setting-#{setting.key}"}>
          <h3><code>{setting.key}</code></h3>
          <p>
            <code>{shown(setting)}</code> <span class="micro">{source_note(setting)}</span>
          </p>
          <p class="field-help">{setting.consequence}</p>
          <.reset :if={setting.source == :stored} what={setting.key} resetting={@resetting}>
            {setting.key} goes back to {shown(%{setting | value: setting.deployed})}, the deployment's.
          </.reset>
        </div>
      </section>

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

          <.metric label="Spent" value={figure(spent(@overview))}>
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
            <a :if={item.where} href={item.where} class="button">{item.action}</a>
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
                  <a :if={@console_url} href={"#{@console_url}#/profiles/#{profile.name}"}>{profile.name}</a>
                  <span :if={is_nil(@console_url)}>{profile.name}</span>
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

  attr(:what, :string, required: true)
  attr(:resetting, :string, default: nil)
  slot(:inner_block, required: true)

  # Two clicks, the second beside what it will do: a reset is undone only by setting the
  # value again, in the console, once somebody can sign in to it.
  defp reset(assigns) do
    ~H"""
    <div class="setting__actions">
      <button :if={@resetting != @what} phx-click="confirm-reset" phx-value-what={@what}>
        back to the deployment
      </button>
      <span :if={@resetting == @what} class="confirm">
        {render_slot(@inner_block)}
        <button phx-click="reset" phx-value-what={@what}>put it back</button>
        <button phx-click="cancel">no</button>
      </span>
    </div>
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
