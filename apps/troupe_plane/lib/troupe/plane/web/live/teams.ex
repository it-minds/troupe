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
      |> put_integer(:cache_eviction_days, params["cache_eviction_days"])
      |> put_integer(:erase_after_days, params["erase_after_days"])
      |> put_string(:budget_period, params["budget_period"])
      |> put_string(:volume_size, params["volume_size"])
      |> put_string(:volume_storage_class, params["volume_storage_class"])
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
      "sponsor" => params["sponsor"],
      "profiles" => params |> Map.get("profiles", "") |> String.split(~r/[,\s]+/, trim: true)
    }

    case Admin.principal_create(socket.assigns.actor, name, attrs) do
      {:ok, principal} -> shown_once(socket, principal)
      # The reason, not only the word. Four things can be wrong with a sponsor and a
      # form that said "invalid_params" to all of them would leave the person guessing
      # which.
      {:error, error} -> {:noreply, assign(socket, flash_message: refusal(error))}
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

  # Three states rather than two, because a principal whose sponsor left is a field to
  # fill in and a principal somebody disabled is a decision, and a list that said
  # "disabled" to both would send people looking for a fault that is not there.
  defp state_note(%{state: :needs_sponsor}), do: "· needs a sponsor"
  defp state_note(%{state: :disabled}), do: "· disabled"
  defp state_note(_principal), do: ""

  # What the plane refused, in the words it used. `Admin.principal_create/3` distinguishes
  # a missing sponsor from a misspelt one from one who has left from one on another team,
  # and every one of those is a different thing to do next.
  defp refusal(%{data: %{reason: reason}}) when is_binary(reason), do: reason
  defp refusal(%{data: %{missing: field}}) when is_binary(field), do: "#{field} is required"
  defp refusal(error), do: error.message

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

  # A field left blank is a field nobody changed, not a field set to nothing. Every one of
  # these has a meaning at its current value and none of them has a meaning as `""`.
  defp put_string(attrs, _key, nil), do: attrs
  defp put_string(attrs, _key, ""), do: attrs
  defp put_string(attrs, key, value), do: Map.put(attrs, key, value)

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
    <.shell actor={@actor} breakglass={@breakglass} page={:teams}>
      <p :if={@error} class="error">{@error}</p>
      <p :if={@flash_message} class="notice">{@flash_message}</p>

      <div :for={team <- @teams} class="team">
        <h2>{team.name}</h2>

        <.title_block>
          <:field label="spent">
            <.amount micros={team.spent_micros} />
          </:field>
          <:field label="reserved">
            <.amount micros={team.reserved_micros} />
          </:field>
          <:field label="against budget">
            <.budget team={team} />
          </:field>
          <:field label="goes dormant after">{team.idle_timeout_seconds}s idle</:field>
          <:field label="cache kept">{team.cache_eviction_days} days</:field>
          <:field label="erased after">{team.erase_after_days} days</:field>
          <:field label="members may">
            {if team.members_may_control, do: "steer sessions", else: "watch only"}
          </:field>
          <:field label="pinning">
            {if team.pins_allowed, do: "allowed", else: "not allowed"}
          </:field>
          <:field label="team volume">
            {team.volume_size} on {team.volume_storage_class || "the default class"}
          </:field>
        </.title_block>

        <form :if={@editing == team.name} id={"edit-#{team.name}"} phx-submit="save">
          <input type="hidden" name="team" value={team.name} />

          <div class="setting">
            <label>
              budget, in millionths
              <input type="number" name="budget_micros" value={team.budget_micros} />
            </label>
            <p class="field-help">
              What this team may spend in a period. 0 is no ceiling at all. At the ceiling
              a new session is refused rather than a running one being stopped.
            </p>
          </div>

          <div class="setting">
            <label>
              period
              <select name="budget_period">
                <option value="monthly" selected={team.budget_period == "monthly"}>monthly</option>
                <option value="daily" selected={team.budget_period == "daily"}>daily</option>
              </select>
            </label>
            <p class="field-help">When the total goes back to zero.</p>
          </div>

          <div class="setting">
            <label>
              idle timeout, in seconds
              <input
                type="number"
                name="idle_timeout_seconds"
                value={team.idle_timeout_seconds}
              />
            </label>
            <p class="field-help">
              How long a session sits with nothing happening before its actors are released
              and it goes dormant. A dormant session costs nothing and wakes with its
              history; shorter frees pod memory sooner, longer means fewer wakes.
            </p>
          </div>

          <div class="setting">
            <label>
              cache kept, in days
              <input type="number" name="cache_eviction_days" value={team.cache_eviction_days} />
            </label>
            <p class="field-help">
              How long a dormant session keeps the working copy it can wake straight back
              into. After this it still wakes, from the log, more slowly.
            </p>
          </div>

          <div class="setting">
            <label>
              erased after, in days
              <input type="number" name="erase_after_days" value={team.erase_after_days} />
            </label>
            <p class="field-help">
              When a session is destroyed for good. Irreversible, and it happens without
              anybody pressing anything.
            </p>
          </div>

          <div class="setting">
            <label>
              team volume size
              <input name="volume_size" value={team.volume_size} />
            </label>
            <p class="field-help">
              A Kubernetes quantity, such as 10Gi. The shared disk this team's sessions
              mount. Changing it after the volume exists needs the storage class to support
              expansion.
            </p>
          </div>

          <div class="setting">
            <label>
              team volume storage class
              <input name="volume_storage_class" value={team.volume_storage_class} />
            </label>
            <p class="field-help">
              Empty means the cluster's default class.
            </p>
          </div>

          <div class="setting">
            <label class="toggle">
              <input type="checkbox" name="members_may_control" checked={team.members_may_control} />
              members may steer a session, not only watch it
            </label>
            <p class="field-help">
              What team visibility grants. Off, a colleague can follow a session and cannot
              type into it.
            </p>
          </div>

          <div class="setting">
            <label class="toggle">
              <input type="checkbox" name="pins_allowed" checked={team.pins_allowed} />
              members may pin a session against eviction
            </label>
            <p class="field-help">
              A pinned session keeps its cache past the eviction window.
            </p>
          </div>

          <div class="setting__actions">
            <button type="submit">save</button>
            <button type="button" phx-click="cancel">cancel</button>
          </div>
        </form>

        <button :if={@editing != team.name} phx-click="edit" phx-value-team={team.name}>edit</button>

        <h3>Spend</h3>
        <p :if={team.spend_by_model == []} class="empty">
          Nothing charged yet. A model call is recorded when the pod running it reports
          what the gateway billed.
        </p>
        <ul :if={team.spend_by_model != []} class="spend">
          <li :for={row <- team.spend_by_model}>
            <code>{row.key || "unknown"}</code>
            — {money(row.cost_micros)} over {row.calls} call(s),
            {row.input_tokens} in / {row.output_tokens} out
          </li>
        </ul>

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

        <form id={"grant-#{team.name}"} :if={@actor.role == :platform_admin} phx-submit="grant">
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

        <form id={"add-admin-#{team.name}"} :if={@actor.role == :platform_admin} phx-submit="add-admin">
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
              {if p.sponsor, do: "· sponsored by #{p.sponsor}"}
              {state_note(p)}
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

        <form id={"new-principal-#{team.name}"} phx-submit="create-principal">
          <input type="hidden" name="team" value={team.name} />
          <label>name <input name="name" placeholder="nightly-deps" /></label>
          <label>profiles <input name="profiles" placeholder="dev, review" /></label>
          <label>
            sponsor
            <input name="sponsor" list={"members-#{team.name}"} placeholder="somebody in this team" />
          </label>
          <datalist id={"members-#{team.name}"}>
            <option :for={member <- team.members} value={member} />
          </datalist>
          <p class="hint">
            A person in this team, answerable for what it does. If they leave, it stops
            firing and appears here as needing a sponsor.
          </p>
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
