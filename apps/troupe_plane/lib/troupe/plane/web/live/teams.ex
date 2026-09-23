defmodule Troupe.Plane.Web.Live.Teams do
  @moduledoc """
  Teams, the groups they draw their members from, their grants, budgets and retention —
  and their members, read-only.

  Members are shown and cannot be edited. Showing them matters: an administrator setting
  a team's budget wants to know how many people it is for. Editing them is not on offer
  because membership comes from the identity provider, and a panel that let somebody add
  a member would be a second source of truth for who is in a team.

  What *is* editable is which groups count. A team draws its members from any number of
  them and its membership is the union, so linking a group is how a team gets people —
  and unlinking one is destructive enough to want the count first, which is the whole of
  the confirmation here.

  The page opens on a table — one row per team, its groups, how many people, which
  profiles — because that is the question somebody arriving here has, and the long card
  under each row is the answer to the next one. *Delete* lives on the row and asks first,
  with what would go and what would stay.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       flash_message: nil,
       editing: nil,
       unlinking: nil,
       unlink_effect: nil,
       disabling: nil,
       disable_effect: nil
     )
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("edit", %{"team" => name}, socket),
    do: {:noreply, assign(socket, editing: name)}

  def handle_event("cancel", _params, socket) do
    {:noreply,
     assign(socket,
       editing: nil,
       unlinking: nil,
       unlink_effect: nil,
       disabling: nil,
       disable_effect: nil,
       confirming: nil
     )}
  end

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
      |> allow_unenforced(socket.assigns.actor, params)

    respond(socket, Admin.team_update(socket.assigns.actor, name, attrs), "#{name} updated")
  end

  # A person's own ceiling, set from the team page because that is where somebody is
  # looking when they wonder who is near theirs. The cap itself is not the team's: it
  # follows them into every team they are in, which is what the flash says.
  def handle_event("person-cap", %{"subject" => subject} = params, socket) do
    micros = params["budget_micros"]

    respond(
      socket,
      Admin.person_budget(socket.assigns.actor, subject, cap_of(micros)),
      "#{subject}: #{cap_note(cap_of(micros))} in every team"
    )
  end

  # Turning a provider group into a team. Done from the CLI or the API before this, which
  # made the first team of a new deployment a shell step in the middle of a console
  # somebody was otherwise configuring everything from.
  #
  # The name is asked for rather than taken from the group: a group is called
  # `itm-consultants` because of how somebody's directory is organised, and a team is
  # called `delivery` because of what it does. One group may be two teams, so the name is
  # the team's own and not a copy of the group's.
  def handle_event("enable-team", %{"group" => group} = params, socket) do
    attrs =
      %{}
      |> put_string("name", params["name"])
      |> put_integer("budget_micros", params["budget_micros"])

    respond(
      socket,
      Admin.team_enable(socket.assigns.actor, group, attrs),
      "#{name_for(params, group)} is a team now, drawing its members from #{group}"
    )
  end

  def handle_event("link", %{"team" => name, "group" => group}, socket) do
    respond(
      socket,
      Admin.team_link(socket.assigns.actor, name, group),
      "#{name} now draws its members from #{group} as well"
    )
  end

  # The count before the deed, like every other irreversible action. Somebody unlinking a
  # group is usually right about which group and often wrong about how many people are in
  # the team *only* through it.
  def handle_event("confirm-unlink", %{"team" => name, "group" => group}, socket) do
    case Admin.team_unlink_preview(socket.assigns.actor, name, group) do
      {:ok, effect} -> {:noreply, assign(socket, unlinking: {name, group}, unlink_effect: effect)}
      {:error, error} -> {:noreply, assign(socket, flash_message: error.message)}
    end
  end

  def handle_event("unlink", %{"team" => name, "group" => group}, socket) do
    socket = assign(socket, unlinking: nil, unlink_effect: nil)

    respond(
      socket,
      Admin.team_unlink(socket.assigns.actor, name, group),
      "#{name} no longer draws its members from #{group}"
    )
  end

  # What goes and what stays, before the row is gone. A team reads as a label and is not:
  # it is what its triggers, principals and grants hang off, and the dialog lists them.
  def handle_event("confirm-disable", %{"team" => name}, socket) do
    case Admin.team_disable_preview(socket.assigns.actor, name) do
      {:ok, effect} -> {:noreply, assign(socket, disabling: name, disable_effect: effect)}
      {:error, error} -> {:noreply, assign(socket, flash_message: error.message)}
    end
  end

  def handle_event("disable", %{"team" => name}, socket) do
    socket = assign(socket, disabling: nil, disable_effect: nil)

    respond(
      socket,
      Admin.team_disable(socket.assigns.actor, name),
      "#{name} is no longer a team; its sessions are kept, with no team"
    )
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

  # What the plane refused, in the words it used. `Admin.principal_create/3` distinguishes
  # a missing sponsor from a misspelt one from one who has left from one on another team,
  # and every one of those is a different thing to do next.
  # A widening refused by the ladder, which is the one refusal whose useful content is a
  # number the reader does not have. The generic clause below matches this error too —
  # it carries `reason: "a lower rung may only narrow"` — and quoting the rule without
  # the ceiling tells an administrator the half they already worked out from the refusal.
  defp refusal(%{data: %{field: field, asked: asked, ceiling: ceiling, decided_by: rung}}) do
    "#{field}: #{asked} is wider than #{ceiling}, which the #{rung} decided. " <>
      "A lower rung may only narrow, so ask for less here or change it there."
  end

  defp refusal(%{data: %{reason: reason}}) when is_binary(reason), do: reason
  defp refusal(%{data: %{missing: field}}) when is_binary(field), do: "#{field} is required"
  defp refusal(error), do: error.message

  defp respond(socket, {:ok, _result}, message) do
    {:noreply, socket |> assign(flash_message: message, editing: nil) |> load()}
  end

  defp respond(socket, {:error, error}, _message) do
    {:noreply, assign(socket, flash_message: refusal(error))}
  end

  # A blank field clears the cap rather than leaving it alone, which is the opposite of
  # every other field on this page — and is right here, because "no ceiling" is a value
  # somebody means and there is no other way to say it.
  defp cap_of(nil), do: nil
  defp cap_of(""), do: nil

  defp cap_of(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} when number > 0 -> number
      _otherwise -> nil
    end
  end

  # What the ladder makes of a field, and a parenthetical where that is not what this
  # team asked for. The team's own number stays in the edit form: this is the answer to
  # "why is it not what I set", which is a different question from "what did I set".
  defp in_force(team, field) do
    case Enum.find(team.effective, &(&1.field == field)) do
      nil -> Map.get(team, field)
      setting -> setting.value
    end
  end

  defp note(team, field) do
    case Enum.find(team.effective, &(&1.field == field)) do
      %{decided_by: rung, value: value} when rung != :team ->
        if value == Map.get(team, field),
          do: "",
          else: " (#{rung}; this team asked for #{Map.get(team, field)})"

      _otherwise ->
        ""
    end
  end

  # The sentence a dialog puts in front of somebody. Sessions do not move — a session's
  # team is recorded at create and stays — and people assume the opposite, so it says so.
  defp unlink_warning(nil), do: ""

  defp unlink_warning(effect) do
    "removes #{effect.lose_access} of #{effect.in_group} people; " <>
      "#{effect.keep_access} keep access through another group. " <>
      "They lose #{effect.sessions_they_can_open} session(s) they can open now. " <>
      "The sessions stay with the team — only who may open them changes."
  end

  # The sentence in front of the delete button. Sessions are named as *kept* rather than
  # left out, because "delete" reads as taking everything and the one thing it does not
  # take is the one people would miss.
  defp disable_warning(nil), do: ""

  defp disable_warning(effect) do
    Enum.join(
      [
        "removes the team for #{effect.members} people",
        "revokes #{plural(effect.grants, "profile")}",
        "deletes #{plural(effect.principals, "service principal")}",
        "deletes #{plural(effect.triggers, "trigger")}",
        "unlinks #{plural(effect.groups, "group")}",
        "#{effect.sessions_kept} session(s) are kept, with no team and read-only"
      ],
      "; "
    ) <> "."
  end

  defp plural(items, noun) when length(items) == 1, do: "1 #{noun}"
  defp plural(items, noun), do: "#{length(items)} #{noun}s"

  defp cap_note(nil), do: "no spend ceiling"
  defp cap_note(micros), do: "a ceiling of #{money(micros)}"

  # Never `money/1` for what has been spent: that answers "unlimited" for zero, which is
  # right for a ceiling and nonsense for a total.
  defp member_note(member) do
    spent = :erlang.float_to_binary(member.spent_micros / 1_000_000, decimals: 2)

    promised =
      if member.reserved_micros > 0,
        do:
          ", #{:erlang.float_to_binary(member.reserved_micros / 1_000_000, decimals: 2)} promised",
        else: ""

    "#{spent} spent#{promised} · #{cap_note(member.budget_micros && positive(member.budget_micros))}"
  end

  defp positive(micros) when micros > 0, do: micros
  defp positive(_micros), do: nil

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
         {:ok, profiles} <- Admin.profiles_list(socket.assigns.actor),
         {:ok, groups} <- Admin.groups_list(socket.assigns.actor) do
      assign(socket,
        teams: teams,
        profiles: Enum.map(profiles, & &1.name),
        groups: groups,
        error: nil
      )
    else
      {:error, error} ->
        assign(socket, teams: [], profiles: [], error: error.message)
    end
  end

  # Only sent by a platform admin's form, and only mentioned when it was on the page: a
  # team admin's save must not carry the key at all, because `Admin.team_update` refuses an
  # update that mentions it rather than dropping the value — and a form that quietly sent
  # `false` would turn every team admin's save into a refusal.
  defp allow_unenforced(attrs, %{role: :platform_admin}, params) do
    Map.put(attrs, :allow_unenforced_workers, params["allow_unenforced_workers"] == "on")
  end

  defp allow_unenforced(attrs, _actor, _params), do: attrs

  defp name_for(%{"name" => name}, _group) when is_binary(name) and name != "", do: name
  defp name_for(_params, group), do: group

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} breakglass={@breakglass} page={:teams}>
      <p :if={@error} class="error">{@error}</p>
      <p :if={@flash_message} class="notice">{@flash_message}</p>

      <section :if={@actor.role == :platform_admin} class="team">
        <h2>Enable a team</h2>
        <p class="hint">
          A team is a Troupe object that draws its members from the provider's groups. It
          is not the group: one group may be two teams with different budgets and different
          grants, so the name is the team's own — what it does, rather than how somebody's
          directory is organised.
        </p>

        <form id="enable-team" phx-submit="enable-team">
          <label for="enable-team-group">Group</label>
          <select id="enable-team-group" name="group">
            <option :for={group <- @groups} value={group.external_id}>
              {group.external_id} — {group.display_name}
            </option>
          </select>

          <label for="enable-team-name">Team name</label>
          <input
            id="enable-team-name"
            name="name"
            placeholder="delivery"
            autocomplete="off"
          />
          <p class="field-help">
            {Admin.team_name_rule() |> String.capitalize()}. Blank takes one
            from the group's display name.
          </p>

          <label for="enable-team-budget">Ceiling, in micros</label>
          <input
            id="enable-team-budget"
            name="budget_micros"
            inputmode="numeric"
            placeholder="blank is no ceiling"
            autocomplete="off"
          />

          <button type="submit">enable</button>
        </form>
      </section>

      <section class="panel">
        <h2>Teams</h2>
        <p class="hint">
          Every team this plane has, with the groups it draws its members from and the
          profiles it may run. <em>Edit</em> opens the form on the team's card below;
          <em>delete</em> asks first, with what would go and what would stay.
        </p>

        <div class="scroller">
          <table id="teams-table">
            <thead>
              <tr>
                <th>team</th>
                <th>groups</th>
                <th>members</th>
                <th>profiles</th>
                <th>administrators</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={team <- @teams} id={"team-row-#{team.name}"}>
                <th scope="row"><a href={"#team-#{team.name}"}>{team.name}</a></th>
                <td>
                  {team.groups |> Enum.map(&(&1.display_name || &1.external_id)) |> Enum.join(", ")}
                  <span :if={team.groups == []} class="none">none</span>
                </td>
                <td>{length(team.members)}</td>
                <td>
                  {team.grants |> Enum.map(& &1.profile) |> Enum.join(", ")}
                  <span :if={team.grants == []} class="none">none</span>
                </td>
                <td>{length(team.admins)}</td>
                <td>
                  <button :if={@editing != team.name} phx-click="edit" phx-value-team={team.name}>
                    edit
                  </button>
                  <button :if={@editing == team.name} phx-click="cancel">stop editing</button>
                  <button
                    :if={@actor.role == :platform_admin and @disabling != team.name}
                    phx-click="confirm-disable"
                    phx-value-team={team.name}
                  >
                    delete
                  </button>
                  <span :if={@disabling == team.name} class="confirm">
                    {disable_warning(@disable_effect)}
                    <button phx-click="disable" phx-value-team={team.name}>delete it</button>
                    <button phx-click="cancel">no</button>
                  </span>
                </td>
              </tr>
              <tr :if={@teams == []}>
                <td colspan="6" class="none">
                  No team yet. Enable a group above, and it appears here.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <div :for={team <- @teams} class="team" id={"team-#{team.name}"}>
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
          <:field label="goes dormant after">
            {in_force(team, :idle_timeout_seconds)}s idle{note(team, :idle_timeout_seconds)}
          </:field>
          <:field label="cache kept">
            {in_force(team, :cache_eviction_days)} days{note(team, :cache_eviction_days)}
          </:field>
          <:field label="erased after">
            {in_force(team, :erase_after_days)} days{note(team, :erase_after_days)}
          </:field>
          <:field label="members may">
            {if in_force(team, :members_may_control), do: "steer sessions", else: "watch only"}{note(
              team,
              :members_may_control
            )}
          </:field>
          <:field label="pinning">
            {if in_force(team, :pins_allowed), do: "allowed", else: "not allowed"}{note(
              team,
              :pins_allowed
            )}
          </:field>
          <:field label="team volume">
            {team.volume_size} on {team.volume_storage_class || "the default class"}
          </:field>
          <:field label="unenforced workers">
            {if team.allow_unenforced_workers, do: "allowed", else: "not allowed"}
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
                <option
                  :for={period <- Admin.budget_periods()}
                  value={period}
                  selected={team.budget_period == period}
                >
                  {period}
                </option>
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

          <div :if={@actor.role == :platform_admin} class="setting">
            <label class="toggle">
              <input
                type="checkbox"
                name="allow_unenforced_workers"
                checked={team.allow_unenforced_workers}
              />
              may run where nothing is enforced
            </label>
            <p class="field-help">
              A worker outside Kubernetes has no admission policy, no network policy, no
              egress by hostname and no disruption budget. Off, a grant to such a profile is
              refused with the missing guarantees named. This is deliberate friction and not
              a way around the policy — it exists so a developer with one laptop and a team
              with one build box can use the product. The Provisioners screen says which
              profiles this is about.
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

        <h3>Where each value comes from</h3>
        <p class="hint">
          A lower rung may only narrow. Where a team's own value is wider than the rung
          above it, the tighter one is in force and the team's is left where it was — so
          widening the platform again gives it back.
        </p>
        <table class="ladder">
          <thead>
            <tr>
              <th>setting</th>
              <th>in force</th>
              <th>decided by</th>
              <th>every opinion</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={setting <- team.effective}>
              <td><code>{setting.key}</code></td>
              <td>{to_string(setting.value)}</td>
              <td>{setting.decided_by}</td>
              <td>
                {setting.opinions
                |> Enum.map(fn opinion -> "#{opinion.rung} #{opinion.value}" end)
                |> Enum.join(", ")}
              </td>
            </tr>
          </tbody>
        </table>

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

        <h3>Groups</h3>
        <p class="hint">
          A team draws its members from any number of the identity provider's groups, and
          its membership is the union — somebody in two of them is in the team once. This
          list is what an administrator edits. Who is in the groups is still the provider's
          answer and is not editable here.
        </p>
        <ul class="groups">
          <li :for={group <- team.groups}>
            <code>{group.external_id}</code> — {group.display_name}
            <button
              :if={@actor.role == :platform_admin and @unlinking != {team.name, group.external_id}}
              phx-click="confirm-unlink"
              phx-value-team={team.name}
              phx-value-group={group.external_id}
            >
              unlink
            </button>
            <span :if={@unlinking == {team.name, group.external_id}} class="confirm">
              {unlink_warning(@unlink_effect)}
              <button phx-click="unlink" phx-value-team={team.name} phx-value-group={group.external_id}>
                unlink it
              </button>
              <button phx-click="cancel">no</button>
            </span>
          </li>
          <li :if={team.groups == []} class="none">
            no groups yet, so no members — which is what a team looks like while you are
            still deciding which groups belong in it
          </li>
        </ul>

        <form id={"link-#{team.name}"} :if={@actor.role == :platform_admin} phx-submit="link">
          <input type="hidden" name="team" value={team.name} />
          <select name="group">
            <option :for={group <- @groups} value={group.external_id}>
              {group.external_id} — {group.display_name}
            </option>
          </select>
          <button type="submit">link a group</button>
        </form>

        <h3>Members</h3>
        <p class="hint">
          From the identity provider, and read-only here — except a person's own spend
          ceiling, which is Troupe's and follows them into every team they are in.
          Blank is no ceiling.
        </p>
        <ul class="members">
          <li :for={member <- team.members}>
            {member.subject}
            <span class="none">{member_note(member)}</span>
            <form
              :if={@actor.role == :platform_admin}
              id={"cap-#{team.name}-#{member.subject}"}
              phx-submit="person-cap"
            >
              <input type="hidden" name="subject" value={member.subject} />
              <input
                type="number"
                name="budget_micros"
                value={member.budget_micros}
                placeholder="no cap"
              />
              <button type="submit">set cap</button>
            </form>
          </li>
          <li :if={team.members == []} class="none">nobody</li>
        </ul>
      </div>
    </.shell>
    """
  end
end
