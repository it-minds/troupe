defmodule Troupe.Plane.Web.Live.Provisioners do
  @moduledoc """
  What can make a worker, and which guarantee each one does not give.

  The right-hand column is this screen's most important content, and it is the reason the
  screen exists rather than being a row on Fleet. A worker outside Kubernetes does not have
  the guarantees Kubernetes was providing — no admission policy, no NetworkPolicy, no FQDN
  egress, no disruption budget — and that is not a footnote for a migration guide.

  ## Four names, not one word

  `unenforced` is not a useful thing to tell somebody who has to decide whether their
  team's work may run on somebody's build box. So every guarantee is listed by name and
  marked given or not given, per provisioner and again per profile.

  ## The friction is the feature

  A profile no substrate enforces may be granted to a team only where a platform admin has
  set `allow_unenforced_workers` for that team, and the grant is refused with the missing
  guarantees quoted until they have. This screen shows which teams have been allowed, and
  says plainly that this is not a way around the policy.

  A console that softened that would be the most dangerous thing in the console, so the
  page states it where somebody is deciding rather than in a document they will not read.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(profiles: [], teams: [], substrates: [], error: nil) |> load()}
  end

  # Three answers, all through `Admin`. What a substrate guarantees is not read out of
  # `Fleet` here — `mix troupe.boundaries` would fail the build, and the reason it would
  # is the reason not to want it: a console with a private path into the plane is a path
  # no other client has.
  defp load(socket) do
    with {:ok, substrates} <- Admin.provisioners(socket.assigns.actor),
         {:ok, profiles} <- Admin.profiles_list(socket.assigns.actor),
         {:ok, teams} <- Admin.teams_list(socket.assigns.actor) do
      assign(socket, substrates: substrates, profiles: profiles, teams: teams, error: nil)
    else
      {:error, error} ->
        assign(socket, substrates: [], profiles: [], teams: [], error: describe(error))
    end
  end

  defp describe(%{message: message, data: %{reason: reason}}), do: "#{message}: #{reason}"
  defp describe(%{message: message}), do: message

  # Every guarantee any substrate here names, in a stable order, so the table has rows
  # even where one provisioner has never heard of one of them.
  defp every_guarantee(substrates) do
    substrates
    |> Enum.flat_map(&(&1.guarantees ++ &1.missing))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp gives?(substrate, guarantee), do: guarantee in substrate.guarantees

  defp guarantee_name("admission_policy"), do: "admission policy"
  defp guarantee_name("network_policy"), do: "network policy"
  defp guarantee_name("fqdn_egress"), do: "egress by hostname"
  defp guarantee_name("disruption_budget"), do: "disruption budget"
  defp guarantee_name(other), do: String.replace(to_string(other), "_", " ")

  defp unenforced(profiles), do: Enum.filter(profiles, &(&1.missing_guarantees != []))

  defp allowed(teams), do: Enum.filter(teams, & &1.allow_unenforced_workers)

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns = assign(assigns, :guarantees, every_guarantee(assigns.substrates))

    ~H"""
    <.shell actor={@actor} breakglass={@breakglass} page={:provisioners}>
      <h1>Provisioners</h1>
      <p class="lede">
        What can make a worker exist — and, for each, which guarantee it does not give.
        Four names rather than one word, because "unenforced" is not something anybody can
        act on when they are deciding whether their team's work may run there.
      </p>

      <p :if={@error} class="banner banner--breakglass" role="alert">{@error}</p>

      <section class="panel">
        <h2>What each one guarantees</h2>

        <div class="scroller">
          <table>
            <thead>
              <tr>
                <th>guarantee</th>
                <th :for={substrate <- @substrates}>{substrate.name}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={guarantee <- @guarantees}>
                <th scope="row">{guarantee_name(guarantee)}</th>
                <td :for={substrate <- @substrates}>
                  <span :if={gives?(substrate, guarantee)}>enforced</span>
                  <span :if={not gives?(substrate, guarantee)} class="rung rung--deployment">
                    not given
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p class="field-help">
          Every one of these is enforced by Kubernetes whether or not the plane is running,
          which is what the rest of the design leans on. A machine somebody already has is
          not a cluster, and the honest answer there is this list rather than a flag.
        </p>
      </section>

      <section class="panel">
        <h2>Every profile, and what its workers do not get</h2>

        <div class="scroller">
          <table>
            <thead>
              <tr>
                <th>profile</th>
                <th>provisioner</th>
                <th>workers</th>
                <th>not given</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={profile <- @profiles}>
                <th scope="row">{profile.name}</th>
                <td>{profile.provisioner}</td>
                <td>{profile.replicas} × {profile.sessions_per_pod}</td>
                <td>
                  <span :if={profile.missing_guarantees == []}>everything is enforced</span>
                  <span
                    :for={missing <- profile.missing_guarantees}
                    class="rung rung--deployment"
                  >
                    {guarantee_name(missing)}
                  </span>
                </td>
              </tr>
              <tr :if={@profiles == []}>
                <td colspan="4" class="none">No profile exists yet.</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="panel">
        <h2>Who may run where nothing is enforced</h2>
        <p class="hint">
          <strong>This is deliberate friction and it is not a way around the policy.</strong>
          It exists so a developer with one laptop and a team with one build box can use the
          product. A grant to a profile no substrate enforces is refused, with the missing
          guarantees quoted, until a platform admin has allowed it for that team by name.
        </p>

        <p :if={unenforced(@profiles) == []} class="empty">
          Every profile here is on a substrate that enforces, so nothing needs allowing.
        </p>

        <ul :if={unenforced(@profiles) != []} class="checks">
          <li :for={team <- allowed(@teams)} class="checks__ok">
            <span class="checks__name">{team.name}</span>
            <span class="checks__detail">
              may be granted a profile nothing enforces. Set by a platform admin, and in the
              audit trail.
            </span>
          </li>

          <li :if={allowed(@teams) == []} class="checks__bad">
            <span class="checks__name">nobody</span>
            <span class="checks__detail">
              No team may be granted
              {unenforced(@profiles) |> Enum.map_join(", ", & &1.name)}. The grant is refused
              until a platform admin allows it on the Teams screen.
            </span>
          </li>
        </ul>
      </section>
    </.shell>
    """
  end
end
