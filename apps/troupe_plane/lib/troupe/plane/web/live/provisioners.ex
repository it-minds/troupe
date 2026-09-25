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

  Where a weaker one stands in, the page says which rather than round it either way. A
  Kubernetes profile without Cilium does not have egress by hostname — its allowlist is
  checked at admission, not on the wire — and "enforced" would be a claim the cluster
  never made, while "not given" alone would hide the check it does make.

  ## The friction is the feature

  A profile no substrate enforces may be granted to a team only where a platform admin has
  set `allow_unenforced_workers` for that team, and the grant is refused with the missing
  guarantees quoted until they have. This screen shows which teams have been allowed, and
  says plainly that this is not a way around the policy.

  A console that softened that would be the most dangerous thing in the console, so the
  page states it where somebody is deciding rather than in a document they will not read.

  ## Machines, which is the other half of the SSH provisioner

  `Troupe.Plane.Fleet.Hosts` had existed since R6 and nothing called it: a host could be
  registered by a function inside the plane and by no person anywhere, which made the
  single-machine case a feature the code had and the product did not. This is where a
  machine is registered, its secret minted, rotated, and stopped.

  **The secret crosses once.** It is in the notice after registering or rotating and in no
  page after the next event, in no process state and in no table — the same discipline a
  service principal's is held to, because a secret the plane could show twice is a secret
  the plane is keeping.

  "Registered and never seen" is its own state and the one somebody needs: a machine nobody
  has installed the worker on yet is a different job from a machine that is switched off.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       profiles: [],
       teams: [],
       substrates: [],
       hosts: %{},
       flash_message: nil,
       error: nil
     )
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("register-host", %{"profile" => profile} = params, socket) do
    attrs = %{"name" => params["name"], "address" => params["address"]}

    case Admin.host_register(socket.assigns.actor, profile, attrs) do
      {:ok, host} -> shown_once(socket, host, "registered")
      {:error, error} -> {:noreply, assign(socket, flash_message: describe(error))}
    end
  end

  def handle_event("rotate-host", %{"profile" => profile, "name" => name}, socket) do
    case Admin.host_rotate(socket.assigns.actor, profile, name) do
      {:ok, host} -> shown_once(socket, host, "has a new secret")
      {:error, error} -> {:noreply, assign(socket, flash_message: describe(error))}
    end
  end

  def handle_event("host-enabled", %{"profile" => profile, "name" => name} = params, socket) do
    enabled? = params["enabled"] == "true"

    case Admin.host_set_enabled(socket.assigns.actor, profile, name, enabled?) do
      {:ok, _host} ->
        said = if enabled?, do: "may enrol again", else: "will not enrol again"
        {:noreply, socket |> assign(flash_message: "#{name} #{said}") |> load()}

      {:error, error} ->
        {:noreply, assign(socket, flash_message: describe(error))}
    end
  end

  # Once, in the notice. The worker on that machine is configured with it and the plane
  # keeps only a hash — there is no method that shows it again, and losing it means
  # rotating rather than looking it up.
  defp shown_once(socket, host, what) do
    message = "#{host.name} #{what} — secret, shown once: #{host.secret}"
    {:noreply, socket |> assign(flash_message: message) |> load()}
  end

  # Three answers, all through `Admin`. What a substrate guarantees is not read out of
  # `Fleet` here — `mix troupe.boundaries` would fail the build, and the reason it would
  # is the reason not to want it: a console with a private path into the plane is a path
  # no other client has.
  defp load(socket) do
    with {:ok, substrates} <- Admin.provisioners(socket.assigns.actor),
         {:ok, profiles} <- Admin.profiles_list(socket.assigns.actor),
         {:ok, teams} <- Admin.teams_list(socket.assigns.actor) do
      assign(socket,
        substrates: substrates,
        profiles: profiles,
        teams: teams,
        hosts: hosts_of(socket.assigns.actor, profiles),
        error: nil
      )
    else
      {:error, error} ->
        assign(socket,
          substrates: [],
          profiles: [],
          teams: [],
          hosts: %{},
          error: describe(error)
        )
    end
  end

  # Asked only of the profiles whose substrate makes workers out of machines. A Kubernetes
  # profile has no hosts and never will, and a listing that asked anyway would answer an
  # empty list that reads as "none registered yet".
  defp hosts_of(actor, profiles) do
    for profile <- profiles, profile.provisioner == "ssh", into: %{} do
      case Admin.hosts_list(actor, profile.name) do
        {:ok, hosts} -> {profile.name, hosts}
        {:error, _error} -> {profile.name, []}
      end
    end
  end

  defp host_note(%{state: :never_seen}),
    do: "registered, never seen — the worker is not installed there yet, or cannot reach here"

  defp host_note(%{state: :disabled}), do: "will not enrol again"
  defp host_note(%{last_enrolled_at: at}), do: "last enrolled #{at}"

  defp describe(%{message: message, data: %{reason: reason}}), do: "#{message}: #{reason}"
  defp describe(%{message: message}), do: message

  # Every guarantee any substrate here names, in a stable order, so the table has rows
  # even where one provisioner has never heard of one of them. A weaker one given in
  # place of a missing one is not a row of its own: it is what that row's cell says.
  defp every_guarantee(substrates) do
    substrates
    |> Enum.flat_map(&((&1.guarantees ++ &1.missing) -- Map.values(&1.instead)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp gives?(substrate, guarantee), do: guarantee in substrate.guarantees

  # A weaker guarantee given in its place is named, because "not given" alone would say
  # that a cluster without Cilium checks the allowlist nowhere at all.
  defp not_given(substrate, guarantee) do
    case Map.fetch(substrate.instead, guarantee) do
      {:ok, weaker} -> "not given: " <> guarantee_name(weaker)
      :error -> "not given"
    end
  end

  defp guarantee_name("admission_policy"), do: "admission policy"
  defp guarantee_name("network_policy"), do: "network policy"
  defp guarantee_name("fqdn_egress"), do: "egress by hostname"
  defp guarantee_name("egress_checked_at_admission"), do: "egress allowlist checked at admission"
  defp guarantee_name("disruption_budget"), do: "disruption budget"
  defp guarantee_name(other), do: String.replace(to_string(other), "_", " ")

  # What a weaker guarantee amounts to, said where a profile is missing the stronger one.
  defp instead_note("egress_checked_at_admission"),
    do: "the egress allowlist is checked at admission, not on the wire"

  defp instead_note(other), do: guarantee_name(other) <> " instead"

  defp unenforced(profiles), do: Enum.filter(profiles, & &1.unenforced)

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

      <p :if={@flash_message} class="banner" role="status">{@flash_message}</p>
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
              <tr :for={guarantee <- @guarantees} id={"substrate-#{guarantee}"}>
                <th scope="row">{guarantee_name(guarantee)}</th>
                <td :for={substrate <- @substrates}>
                  <span :if={gives?(substrate, guarantee)}>enforced</span>
                  <span :if={not gives?(substrate, guarantee)} class="rung rung--deployment">
                    {not_given(substrate, guarantee)}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p class="field-help">
          Egress by hostname is Cilium's, and a cluster need not have it. A Kubernetes profile
          has it where the operator reports that it wrote that profile's FQDN rules, which the
          next table says profile by profile; without them the allowlist is checked at
          admission and at every reconcile, and a worker reaches any public host on 443 and
          80. The rest are enforced by Kubernetes whether or not the plane is running, which
          is what the rest of the design leans on. A machine somebody already has is not a
          cluster, and the honest answer there is this list rather than a flag.
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
              <tr :for={profile <- @profiles} id={"guarantees-#{profile.name}"}>
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
                  <span :for={{_missing, weaker} <- profile.guarantees_instead} class="field-help">
                    {instead_note(weaker)}
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

      <section :for={{profile, hosts} <- @hosts} class="panel">
        <h2>Machines registered to {profile}</h2>
        <p class="hint">
          A host is a machine somebody already has. The plane never dials one — the worker
          dials the plane — so registering a machine mints a secret it enrols with, and the
          secret is shown once. Losing it means rotating rather than looking it up.
        </p>

        <ul :if={hosts != []} class="checks">
          <li
            :for={host <- hosts}
            class={if host.state == :enrolled, do: "checks__ok", else: "checks__bad"}
          >
            <span class="checks__name">{host.name}</span>
            <span class="checks__detail">
              {host.address || "no address recorded"} · {host_note(host)}
            </span>
            <span class="checks__took">
              <button phx-click="rotate-host" phx-value-profile={profile} phx-value-name={host.name}>
                rotate
              </button>
              <button
                phx-click="host-enabled"
                phx-value-profile={profile}
                phx-value-name={host.name}
                phx-value-enabled={to_string(not host.enabled)}
              >
                {if host.enabled, do: "stop it enrolling", else: "let it enrol"}
              </button>
            </span>
          </li>
        </ul>

        <p :if={hosts == []} class="empty">
          No machine is registered to {profile}, so it has no workers and can have none.
        </p>

        <form id={"register-host-#{profile}"} phx-submit="register-host">
          <input type="hidden" name="profile" value={profile} />

          <label for={"host-name-#{profile}"}>A machine for {profile}</label>
          <input id={"host-name-#{profile}"} name="name" placeholder="the build box" autocomplete="off" />
          <input name="address" placeholder="where it is, for your own records" autocomplete="off" />

          <p class="field-help">
            The address is for you. Nothing here connects to it: enrolment is the worker
            dialling this plane with the secret, which is what makes a machine behind NAT
            work at all.
          </p>

          <button type="submit">register</button>
        </form>
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
