defmodule Troupe.Plane.Web.Live.Identity do
  @moduledoc """
  Where people come from, and every credential that is not a person.

  Half of this lived inside Settings and half inside Teams, which is how a service
  principal's *sponsor* — an identity fact if there ever was one — ended up being edited on
  the page about budgets and retention. This is the screen those halves belong on.

  ## The check is the good idea, and it is unchanged

  The useful test is not "is that a valid group" but **"how many people would administer
  this platform afterwards, and are you one of them"**. It asks this plane's own tables who
  has actually arrived carrying the group, because a group that exists in the provider and
  has never appeared in a token grants nobody anything here.

  It runs against the value in the field rather than against what is stored, because the
  whole point of it is to answer "what would happen if I saved this". Policy keeps its own
  copy of the check for the same reason: that is where the value is saved, and a save gated
  on a check somewhere else is a gate somebody walks around.

  ## Three states for a principal, not two

  A principal whose sponsor has left the provider is a field to fill in. A principal
  somebody disabled is a decision. A list that said "disabled" to both would send people
  looking for a fault that is not there — so `state` says which, and a principal needing a
  sponsor is reported as needing one rather than as broken.

  ## What is read-only here, and why it is shown at all

  The provider's groups. Membership is the provider's answer and Troupe having a way to
  edit it would be a second source of truth for who is in a team. They are listed because
  an administrator linking a team to a group needs to know which groups this plane has
  actually seen — a group nobody has signed in from is not a group this plane can use.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       groups: [],
       teams: [],
       principals: %{},
       check: nil,
       candidate: "",
       flash_message: nil,
       error: nil
     )
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("check", params, socket) do
    candidate = presence(params["group"]) || socket.assigns.candidate

    case Admin.identity_check(socket.assigns.actor, presence(candidate)) do
      {:ok, check} -> {:noreply, assign(socket, check: check, candidate: candidate, error: nil)}
      {:error, error} -> {:noreply, assign(socket, check: nil, error: describe(error))}
    end
  end

  def handle_event("create-principal", %{"team" => team} = params, socket) do
    attrs = %{
      "name" => params["name"],
      "description" => params["description"],
      "sponsor" => params["sponsor"],
      "profiles" => params |> Map.get("profiles", "") |> String.split(~r/[,\s]+/, trim: true)
    }

    case Admin.principal_create(socket.assigns.actor, team, attrs) do
      {:ok, principal} -> shown_once(socket, principal)
      {:error, error} -> {:noreply, assign(socket, flash_message: describe(error))}
    end
  end

  def handle_event("rotate-principal", %{"subject" => subject}, socket) do
    case Admin.principal_rotate(socket.assigns.actor, subject) do
      {:ok, principal} -> shown_once(socket, principal)
      {:error, error} -> {:noreply, assign(socket, flash_message: describe(error))}
    end
  end

  def handle_event("disable-principal", %{"subject" => subject}, socket) do
    case Admin.principal_disable(socket.assigns.actor, subject) do
      {:ok, _principal} ->
        {:noreply, socket |> assign(flash_message: "#{subject} disabled") |> load()}

      {:error, error} ->
        {:noreply, assign(socket, flash_message: describe(error))}
    end
  end

  # The secret crosses once, in the notice, and is in no page after the next event, in no
  # process state and in no table.
  defp shown_once(socket, principal) do
    message = "#{principal.subject} — secret, shown once: #{principal.secret}"
    {:noreply, socket |> assign(flash_message: message) |> load()}
  end

  defp load(socket) do
    with {:ok, groups} <- Admin.groups_list(socket.assigns.actor),
         {:ok, teams} <- Admin.teams_list(socket.assigns.actor) do
      principals = Map.new(teams, &{&1.name, principals_of(socket.assigns.actor, &1.name)})
      assign(socket, groups: groups, teams: teams, principals: principals, error: nil)
    else
      {:error, error} ->
        assign(socket, groups: [], teams: [], principals: %{}, error: describe(error))
    end
  end

  defp principals_of(actor, team) do
    case Admin.principals_list(actor, team) do
      {:ok, principals} -> principals
      {:error, _error} -> []
    end
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: value

  defp describe(%{message: message, data: %{reason: reason}}), do: "#{message}: #{reason}"
  defp describe(%{message: message}), do: message

  # Three states, said apart. Needing a sponsor is a field to fill in; disabled is a
  # decision somebody made.
  defp state_note(%{state: :needs_sponsor}), do: "· needs a sponsor"
  defp state_note(%{state: :disabled}), do: "· disabled"
  defp state_note(_principal), do: ""

  defp all_principals(principals), do: principals |> Map.values() |> List.flatten()

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} breakglass={@breakglass} page={:identity}>
      <h1>Identity</h1>
      <p class="lede">
        Where people come from, which group administers this platform, and every credential
        that is not a person. Membership is the provider's answer and is read-only here:
        Troupe having a way to edit it would be a second source of truth for who is in a
        team.
      </p>

      <p :if={@flash_message} class="banner" role="status">{@flash_message}</p>
      <p :if={@error} class="banner banner--breakglass" role="alert">{@error}</p>

      <section class="panel">
        <h2>Who administers this platform</h2>
        <p class="hint">
          The useful question is not whether that is a valid group. It is how many people
          would administer this platform afterwards, and whether you are one of them — so
          this asks the plane's own tables who has actually arrived carrying it. A group
          that exists in the provider and has never appeared in a token grants nobody
          anything here.
        </p>

        <form id="identity-check" phx-submit="check" phx-change="check">
          <label for="identity-check-group">Group</label>
          <input
            id="identity-check-group"
            name="group"
            value={@candidate}
            placeholder="the group as the provider spells it"
            autocomplete="off"
          />
          <button type="submit">run the check</button>
        </form>

        <ul :if={@check} class="checks">
          <li :for={check <- @check.checks} class={if check.ok, do: "checks__ok", else: "checks__bad"}>
            <span class="checks__name">{check.name}</span>
            <span class="checks__detail">{check.detail}</span>
            <span class="checks__took micro">{check.took_ms} ms</span>
          </li>
        </ul>

        <p :if={@check} class="field-help">
          The redirect this console sends is <code>{@check.redirect_uri || "unknown"}</code>.
          No check can prove it is registered — the provider is the only thing that knows —
          so if sign-in comes back with an error, compare it against the registration by
          eye.
        </p>

        <p class="field-help">
          Saving the group is done on <.link navigate="/admin/policy">Policy</.link>, where
          the save is gated on this same check. A save gated on a check somewhere else is a
          gate somebody walks around.
        </p>
      </section>

      <section class="panel">
        <h2>Groups this plane has seen</h2>
        <p class="hint">
          Mirrored, never authored: this list is what SCIM pushed or what somebody's groups
          claim created at login. A group absent from it is one nobody has signed in from,
          and a team cannot draw its members from a group this plane has never seen.
        </p>

        <div class="scroller">
          <table>
            <thead>
              <tr>
                <th>group</th>
                <th>display name</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={group <- @groups}>
                <th scope="row">{group.external_id}</th>
                <td>{group.display_name}</td>
              </tr>
              <tr :if={@groups == []}>
                <td colspan="2" class="none">
                  No group has been seen. Nobody has signed in, or the groups claim is not
                  the one this plane is reading.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="panel">
        <h2>Service principals</h2>
        <p class="hint">
          Credentials a team owns, for triggers and other work nobody starts by hand. A
          secret is shown once, when it is made or rotated. The sponsor is a person
          answerable for what it does — an identity fact, which is why it is here rather
          than scattered across the pages that use one.
        </p>

        <ul class="checks">
          <li
            :for={principal <- all_principals(@principals)}
            class={if principal.enabled, do: "checks__ok", else: "checks__bad"}
          >
            <span class="checks__name">{principal.subject}</span>
            <span class="checks__detail">
              {Enum.join(principal.profiles, ", ")}
              {if principal.description, do: "— #{principal.description}"}
              {if principal.sponsor,
                do: "· sponsored by #{principal.sponsor}",
                else: "· no sponsor"}
              {if principal.last_used_at,
                do: "· last used #{principal.last_used_at}",
                else: "· never used"}
              {state_note(principal)}
            </span>
            <span class="checks__took">
              <button
                :if={principal.enabled}
                phx-click="rotate-principal"
                phx-value-subject={principal.subject}
              >
                rotate
              </button>
              <button
                :if={principal.enabled}
                phx-click="disable-principal"
                phx-value-subject={principal.subject}
              >
                disable
              </button>
            </span>
          </li>

          <li :if={all_principals(@principals) == []} class="checks__ok">
            <span class="checks__name">none</span>
            <span class="checks__detail">
              No team has a principal yet. A trigger that fires unattended needs one.
            </span>
          </li>
        </ul>

        <div :for={team <- @teams} class="setting">
          <form id={"new-principal-#{team.name}"} phx-submit="create-principal">
            <input type="hidden" name="team" value={team.name} />

            <label for={"principal-name-#{team.name}"}>A principal for {team.name}</label>
            <input id={"principal-name-#{team.name}"} name="name" placeholder="nightly-deps" />
            <input name="profiles" placeholder="dev, review" />
            <input
              name="sponsor"
              list={"members-#{team.name}"}
              placeholder="somebody in this team"
            />
            <datalist id={"members-#{team.name}"}>
              <option :for={member <- team.members} value={member.subject}></option>
            </datalist>
            <input name="description" placeholder="what it is for" />

            <p class="field-help">
              The sponsor is a person in this team, answerable for what it does. If they
              leave the provider it stops firing and appears above as needing a sponsor —
              which invites the correct action, where "broken" would invite a restart.
            </p>

            <button type="submit">create</button>
          </form>
        </div>
      </section>
    </.shell>
    """
  end
end
