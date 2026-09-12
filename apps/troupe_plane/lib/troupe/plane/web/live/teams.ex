defmodule Troupe.Plane.Web.Live.Teams do
  @moduledoc """
  Teams, their grants, budgets and retention — and their members, read-only.

  Members are shown and cannot be edited. Showing them matters: an administrator setting
  a team's budget wants to know how many people it is for. Editing them is not on offer
  because membership comes from the identity provider, and a panel that let somebody add
  a member would be a second source of truth for who is in a team.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(flash_message: nil, editing: nil) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("edit", %{"team" => name}, socket),
    do: {:noreply, assign(socket, editing: name)}

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("save", %{"team" => name} = params, socket) do
    attrs =
      %{}
      |> put_integer(:budget_micros, params["budget_micros"])
      |> put_integer(:idle_timeout_seconds, params["idle_timeout_seconds"])
      |> put_integer(:erase_after_days, params["erase_after_days"])
      |> Map.put(:members_may_control, params["members_may_control"] == "on")
      |> Map.put(:pins_allowed, params["pins_allowed"] == "on")

    respond(socket, Admin.team_update(socket.assigns.actor, name, attrs), "#{name} updated")
  end

  def handle_event("grant", %{"team" => name, "profile" => profile}, socket) do
    respond(
      socket,
      Admin.team_grant(socket.assigns.actor, name, profile),
      "#{name} granted #{profile}"
    )
  end

  def handle_event("revoke", %{"team" => name, "profile" => profile}, socket) do
    respond(
      socket,
      Admin.team_revoke(socket.assigns.actor, name, profile),
      "#{name} lost #{profile}; its sessions there are now read-only"
    )
  end

  def handle_event("add-admin", %{"team" => name, "subject" => subject}, socket) do
    respond(
      socket,
      Admin.team_admin_add(socket.assigns.actor, name, subject),
      "#{subject} administers #{name}"
    )
  end

  def handle_event("remove-admin", %{"team" => name, "subject" => subject}, socket) do
    respond(
      socket,
      Admin.team_admin_remove(socket.assigns.actor, name, subject),
      "#{subject} no longer administers #{name}"
    )
  end

  # The secret comes back once and is shown once, in the notice; it is not in the page
  # after the next event, not in this process's state, and not in the plane's database.
  def handle_event("create-principal", %{"team" => name} = params, socket) do
    attrs = %{
      "name" => params["name"],
      "description" => params["description"],
      "profiles" => params |> Map.get("profiles", "") |> String.split(~r/[,\s]+/, trim: true)
    }

    case Admin.principal_create(socket.assigns.actor, name, attrs) do
      {:ok, principal} -> shown_once(socket, principal)
      {:error, error} -> {:noreply, assign(socket, flash_message: error.message)}
    end
  end

  def handle_event("rotate-principal", %{"subject" => subject}, socket) do
    case Admin.principal_rotate(socket.assigns.actor, subject) do
      {:ok, principal} -> shown_once(socket, principal)
      {:error, error} -> {:noreply, assign(socket, flash_message: error.message)}
    end
  end

  def handle_event("disable-principal", %{"subject" => subject}, socket) do
    respond(socket, Admin.principal_disable(socket.assigns.actor, subject), "#{subject} disabled")
  end

  defp shown_once(socket, principal) do
    message = "#{principal.subject} — secret, shown once: #{principal.secret}"
    {:noreply, socket |> assign(flash_message: message, editing: nil) |> load()}
  end

  defp respond(socket, {:ok, _result}, message) do
    {:noreply, socket |> assign(flash_message: message, editing: nil) |> load()}
  end

  defp respond(socket, {:error, error}, _message) do
    {:noreply, assign(socket, flash_message: error.message)}
  end

  defp put_integer(attrs, _key, nil), do: attrs
  defp put_integer(attrs, _key, ""), do: attrs

  defp put_integer(attrs, key, value) do
    case Integer.parse(value) do
      {number, _rest} -> Map.put(attrs, key, number)
      :error -> attrs
    end
  end

  defp load(socket) do
    with {:ok, teams} <- Admin.teams_list(socket.assigns.actor),
         {:ok, profiles} <- Admin.profiles_list(socket.assigns.actor) do
      principals = Map.new(teams, &{&1.name, principals_of(socket.assigns.actor, &1.name)})

      assign(socket,
        teams: teams,
        profiles: Enum.map(profiles, & &1.name),
        principals: principals,
        error: nil
      )
    else
      {:error, error} ->
        assign(socket, teams: [], profiles: [], principals: %{}, error: error.message)
    end
  end

  defp principals_of(actor, team) do
    case Admin.principals_list(actor, team) do
      {:ok, principals} -> principals
      {:error, _error} -> []
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} page={:teams}>
      <p :if={@error} class="error">{@error}</p>
      <p :if={@flash_message} class="notice">{@flash_message}</p>

      <div :for={team <- @teams} class="team">
        <h2>{team.name}</h2>

        <dl class="counts">
          <dt>budget</dt>
          <dd>{money(team.budget_micros)} / {team.budget_period}</dd>
          <dt>idle timeout</dt>
          <dd>{team.idle_timeout_seconds}s</dd>
          <dt>erase after</dt>
          <dd>{team.erase_after_days} days</dd>
          <dt>pins</dt>
          <dd>{if team.pins_allowed, do: "allowed", else: "not allowed"}</dd>
        </dl>

        <form :if={@editing == team.name} phx-submit="save">
          <input type="hidden" name="team" value={team.name} />
          <label>budget (micros) <input name="budget_micros" value={team.budget_micros} /></label>
          <label>idle timeout (s) <input name="idle_timeout_seconds" value={team.idle_timeout_seconds} /></label>
          <label>erase after (days) <input name="erase_after_days" value={team.erase_after_days} /></label>
          <label>
            <input type="checkbox" name="members_may_control" checked={team.members_may_control} /> members may control
          </label>
          <label>
            <input type="checkbox" name="pins_allowed" checked={team.pins_allowed} /> pins allowed
          </label>
          <button type="submit">save</button>
          <button type="button" phx-click="cancel">cancel</button>
        </form>

        <button :if={@editing != team.name} phx-click="edit" phx-value-team={team.name}>edit</button>

        <h3>Grants</h3>
        <ul class="grants">
          <li :for={grant <- team.grants}>
            {grant.profile} ({grant.volume_mode})
            <button
              :if={@actor.role == :platform_admin}
              phx-click="revoke"
              phx-value-team={team.name}
              phx-value-profile={grant.profile}
            >
              revoke
            </button>
          </li>
          <li :if={team.grants == []} class="none">no profiles granted</li>
        </ul>

        <form :if={@actor.role == :platform_admin} phx-submit="grant">
          <input type="hidden" name="team" value={team.name} />
          <select name="profile">
            <option :for={profile <- @profiles} value={profile}>{profile}</option>
          </select>
          <button type="submit">grant</button>
        </form>

        <h3>Administrators</h3>
        <ul class="admins">
          <li :for={subject <- team.admins}>
            {subject}
            <button
              :if={@actor.role == :platform_admin}
              phx-click="remove-admin"
              phx-value-team={team.name}
              phx-value-subject={subject}
            >
              remove
            </button>
          </li>
          <li :if={team.admins == []} class="none">none</li>
        </ul>

        <form :if={@actor.role == :platform_admin} phx-submit="add-admin">
          <input type="hidden" name="team" value={team.name} />
          <input name="subject" placeholder="somebody@example.com" />
          <button type="submit">make an admin</button>
        </form>

        <h3>Service principals</h3>
        <p class="hint">
          Credentials this team owns, for triggers and other work nobody starts by hand. A
          secret is shown once, when it is made or rotated.
        </p>
        <ul class="principals">
          <li :for={p <- Map.get(@principals, team.name, [])} class={if p.enabled, do: "", else: "none"}>
            {p.subject}
            <span class="hint">
              {Enum.join(p.profiles, ", ")}
              {if p.description, do: "— #{p.description}"}
              {if p.last_used_at, do: "· last used #{p.last_used_at}", else: "· never used"}
              {if !p.enabled, do: "· disabled"}
            </span>
            <button :if={p.enabled} phx-click="rotate-principal" phx-value-subject={p.subject}>
              rotate secret
            </button>
            <button :if={p.enabled} phx-click="disable-principal" phx-value-subject={p.subject}>
              disable
            </button>
          </li>
          <li :if={Map.get(@principals, team.name, []) == []} class="none">none</li>
        </ul>

        <form phx-submit="create-principal">
          <input type="hidden" name="team" value={team.name} />
          <label>name <input name="name" placeholder="nightly-deps" /></label>
          <label>profiles <input name="profiles" placeholder="dev, review" /></label>
          <label>description <input name="description" /></label>
          <button type="submit">create a principal</button>
        </form>

        <h3>Members</h3>
        <p class="hint">From the identity provider, and read-only here.</p>
        <ul class="members">
          <li :for={member <- team.members}>{member}</li>
          <li :if={team.members == []} class="none">nobody</li>
        </ul>
      </div>
    </.shell>
    """
  end
end
