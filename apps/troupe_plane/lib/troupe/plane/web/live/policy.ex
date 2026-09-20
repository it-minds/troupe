defmodule Troupe.Plane.Web.Live.Policy do
  @moduledoc """
  The ladder: every setting, what it resolves to here, and which rung decided it.

  This page was called Settings and answered the question for one rung. A value is
  decided at up to five — the deployment, the platform, a team, a profile, a session —
  and a page that showed only what a platform admin had stored left an administrator
  looking at a retention of thirty days where they had set three hundred and sixty-five
  with nowhere to find out who said thirty.

  So the page keeps everything it had and gains the thing it was missing: for every
  setting more than one rung decides, the value in force, the rung that decided it, and
  **every rung that had an opinion, with the value it held.** The losers are in the
  answer rather than only the winner, because "30 days" tells a reader nothing at all
  about why their 365 is not in force.

  ## As one team sees it

  Two rungs are always here — the deployment and the platform — and the third is a team,
  which is where a value usually stops being what somebody expected. The team picker is
  what makes the three-rung case readable: pick a team and its own opinion joins the
  table beside the two above it, with the winner marked and the ceiling named.

  Nothing on this page edits a team. A team's own values are a team admin's and live on
  the Teams screen; this is the view that says what they may not exceed.

  ## What it still does that a settings page usually does not

  The page exists because the honest answer to "where is this platform's configuration"
  used to be "in a values file somebody has, and in an environment variable, and in the
  head of whoever deployed it". Everything is on one page now, including the parts this
  console deliberately cannot change — a read-only row that says why is more use than a
  field that is missing, because a missing field reads as a feature nobody built.

  **It checks before it saves.** `platform_admin_group` is the setting that can lock every
  administrator out of the console, including the person typing. So the field cannot be
  saved until the check beside it has passed *for the value in the field* — and the check
  answers the question that actually matters, which is not "is that a valid group" but
  "how many people would administer this platform afterwards, and are you one of them".
  The design's rule is that identity configuration cannot be saved until a test has
  passed; this is that rule with a test worth passing.

  **It says what a change will do before you make it.** Every field carries the
  consequence of changing it and when it takes effect, in body text under the field rather
  than in a tooltip. A tooltip is something you find after you have already been surprised.

  The panels and the fields both come from the answer to `admin.settings.list`, so a
  setting added to `Troupe.Plane.Settings` appears here without this file changing.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  # The one setting that can lock every administrator out, including whoever is typing.
  # Read through a function rather than the attribute alone because inside a template
  # `@gated` means an assign, not a module attribute, and the two are silently different.
  @gated "platform_admin_group"

  defp gated_key, do: @gated

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       notice: nil,
       error: nil,
       check: nil,
       drafts: %{},
       groups: [],
       settings: [],
       rungs: [],
       laddered: [],
       effective: [],
       teams: [],
       as_team: nil
     )
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("edit", %{"key" => key, "value" => value}, socket) do
    {:noreply, assign(socket, drafts: Map.put(socket.assigns.drafts, key, value))}
  end

  def handle_event("save", %{"key" => key} = params, socket) do
    value = params["value"] || Map.get(socket.assigns.drafts, key, "")

    case Admin.setting_put(socket.assigns.actor, key, value) do
      {:ok, applied} ->
        {:noreply,
         socket
         |> forget(key)
         |> assign(notice: "#{key} is now #{inspect(applied.value)}. #{applied.effect}")
         |> load()}

      {:error, error} ->
        {:noreply, assign(socket, error: describe(error), notice: nil)}
    end
  end

  def handle_event("reset", %{"key" => key}, socket) do
    case Admin.setting_reset(socket.assigns.actor, key) do
      {:ok, applied} ->
        {:noreply,
         socket
         |> forget(key)
         |> assign(notice: "#{key} is back to #{inspect(applied.value)}, from the deployment.")
         |> load()}

      {:error, error} ->
        {:noreply, assign(socket, error: describe(error), notice: nil)}
    end
  end

  # Which team's opinion joins the two above it. A blank selection is the platform's own
  # view — what every team may not exceed — rather than a team that happens to be first.
  def handle_event("as-team", %{"team" => name}, socket) do
    {:noreply, socket |> assign(as_team: presence(name)) |> load()}
  end

  # The check runs against whatever is in the field rather than against what is stored:
  # the whole point of it is to answer "what would happen if I saved this".
  def handle_event("check", _params, socket) do
    group = value_for(socket.assigns, @gated)

    case Admin.identity_check(socket.assigns.actor, group) do
      {:ok, check} -> {:noreply, assign(socket, check: check, error: nil)}
      {:error, error} -> {:noreply, assign(socket, error: describe(error), check: nil)}
    end
  end

  # A saved or reset field is no longer a draft, and the check that unlocked it was about
  # the value it used to have.
  defp forget(socket, key) do
    assign(socket,
      drafts: Map.delete(socket.assigns.drafts, key),
      error: nil,
      check: if(key == @gated, do: nil, else: socket.assigns.check)
    )
  end

  defp load(socket) do
    case Admin.settings_list(socket.assigns.actor) do
      {:ok, answer} ->
        socket
        |> assign(
          # The provider has a screen of its own, where the save is gated on the check;
          # rendering its fields here too would be a second save nobody gated.
          groups: Enum.reject(answer.groups, &(&1.key == :sign_in)),
          settings: answer.settings,
          rungs: answer.ladder,
          laddered: answer.laddered
        )
        |> resolve()
        |> teams()

      {:error, error} ->
        assign(socket, groups: [], settings: [], error: describe(error))
    end
  end

  # One call per laddered setting, which is five. Asked through `Admin` like everything
  # else on this page: the console is an admin API client and gets no private access to
  # the resolver, so a screen and a model reading `admin.setting.effective` are looking
  # at the same answer rather than at two computations of it.
  defp resolve(socket) do
    resolved =
      for key <- socket.assigns.laddered,
          {:ok, answer} <- [
            Admin.setting_effective(socket.assigns.actor, key, socket.assigns.as_team)
          ],
          do: answer

    assign(socket, effective: resolved)
  end

  # For the picker. A team admin sees the teams they administer, which is what
  # `teams_list` already answers — so the picker offers exactly the teams whose values
  # this reader is allowed to know about.
  defp teams(socket) do
    case Admin.teams_list(socket.assigns.actor) do
      {:ok, teams} -> assign(socket, teams: Enum.map(teams, & &1.name))
      {:error, _error} -> assign(socket, teams: [])
    end
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: value

  defp describe(%{message: message, data: %{reason: reason}}), do: "#{message}: #{reason}"
  defp describe(%{message: message}), do: message

  # What a field shows: what has been typed into it, or what the setting is.
  defp value_for(assigns, key) do
    case Map.fetch(assigns.drafts, key) do
      {:ok, typed} -> typed
      :error -> assigns.settings |> Enum.find(&(&1.key == key)) |> stored_value()
    end
  end

  defp stored_value(%{value: value}) when not is_nil(value), do: to_string(value)
  defp stored_value(_missing_or_secret), do: ""

  # Whether the group in the field has been checked and stands up. Not whether *every*
  # check passed: a plane whose provider is briefly unreachable should still be able to fix
  # the group that is locking everybody out, and the provider checks are not what that
  # field depends on.
  defp verified?(nil, _value), do: false

  defp verified?(check, value) do
    check.group == value and Enum.any?(check.checks, &(&1.name == "Platform admins" and &1.ok))
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns = assign(assigns, :unlocked, verified?(assigns.check, value_for(assigns, @gated)))

    ~H"""
    <.shell actor={@actor} breakglass={@breakglass} page={:policy}>
      <h1>Policy</h1>
      <p class="lede">
        What this plane is configured with, and — for every value more than one rung
        decides — which rung decided it. Each field says what it does, what changes when
        you change it, and where the value it has now came from.
      </p>

      <p :if={@notice} class="banner" role="status">{@notice}</p>
      <p :if={@error} class="banner banner--breakglass" role="alert">{@error}</p>

      <p :if={@actor.role != :platform_admin} class="banner">
        <strong>This page is read-only for you.</strong>
        What a platform is configured with is a platform admin's to change, and you
        administer teams. Everything below is what is set; nothing below will save.
      </p>

      <section class="panel">
        <h2>The ladder</h2>
        <p class="lede">
          Five rungs, widest first. A lower rung may only <em>narrow</em> — fewer days, a
          shorter timeout, a permission off — and <strong>deny wins from any rung</strong>,
          because the two ways of writing the same intent must not disagree and the safe
          reading is the one that grants less.
        </p>

        <dl class="rungs">
          <div :for={rung <- @rungs} class="rungs__rung">
            <dt><.rung rung={rung} /></dt>
            <dd>{rung_blurb(rung)}</dd>
          </div>
        </dl>

        <h3>Where each value comes from</h3>
        <p class="field-help">
          Two rungs are always here. Pick a team and its own opinion joins them, which is
          where a value usually stops being the one somebody expected.
        </p>

        <form id="policy-as-team" phx-change="as-team">
          <label for="policy-as-team-select">As seen by</label>
          <select id="policy-as-team-select" name="team">
            <option value="" selected={is_nil(@as_team)}>
              the platform — what no team may exceed
            </option>
            <option :for={team <- @teams} value={team} selected={@as_team == team}>
              {team}
            </option>
          </select>
        </form>

        <div class="scroller">
        <table class="ladder">
          <thead>
            <tr>
              <th>setting</th>
              <th>in force</th>
              <th>decided by</th>
              <th>ceiling for a team</th>
              <th>deployment</th>
              <th>platform</th>
              <th>team</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @effective}>
              <td><code>{row.key}</code></td>
              <td class="mono">{shown_value(row.value)}</td>
              <td><.rung rung={row.decided_by} /></td>
              <td class="mono">{shown_value(row.ceiling)}</td>
              <.opinion row={row} rung={:deployment} />
              <.opinion row={row} rung={:platform} />
              <.opinion row={row} rung={:team} />
            </tr>
            <tr :if={@effective == []}>
              <td colspan="7" class="none">
                No setting on this plane is decided at more than one rung.
              </td>
            </tr>
          </tbody>
        </table>
        </div>

        <p class="field-help">
          A rung with no opinion does not participate, and is shown as <code>&mdash;</code>
          rather than as a zero. Where a team holds a wider value than the rung above it,
          the tighter one is in force and the team&#39;s row is left alone — so widening the
          platform again gives the team its own value back rather than having silently
          rewritten it.
        </p>

        <p :if={not is_nil(@as_team)} class="field-help">
          <strong>{@as_team}</strong> cannot be given a value wider than the ceiling above.
          The attempt is refused on the Teams screen with the ceiling quoted, rather than
          accepted and quietly clamped — a form that took a number the system is not using
          has told somebody a lie it knew about.
        </p>
      </section>

      <section :for={group <- @groups} class="panel">
        <h2>{group.title}</h2>
        <p class="lede">{group.blurb}</p>

        <.setting
          :for={setting <- Enum.filter(@settings, &(&1.group == group.key))}
          setting={setting}
          value={value_for(assigns, setting.key)}
          may_write={@actor.role == :platform_admin}
          gated={setting.key == gated_key()}
          unlocked={@unlocked}
          decided={decided(assigns, setting.key)}
        />

        <div :if={group.key == :administration} class="checks-block">
          <h3>Before you change either of those</h3>
          <p>
            This asks the provider what it publishes, and asks this plane who has actually
            arrived carrying the group in the field above. It changes nothing.
          </p>

          <button type="button" phx-click="check">Run the check</button>

          <.checks :if={@check} check={@check} />
        </div>
      </section>
    </.shell>
    """
  end

  attr(:setting, :map, required: true)
  attr(:value, :string, default: "")
  attr(:may_write, :boolean, required: true)
  attr(:gated, :boolean, default: false)
  attr(:unlocked, :boolean, default: false)
  # `nil` for a setting one rung decides, which is most of them. Where something else
  # decides it, the chip is beside the field rather than in a tooltip — a person who has
  # to hover to find out their number is not the one in force has already been surprised.
  attr(:decided, :map, default: nil)

  defp setting(%{setting: %{editable: false}} = assigns) do
    ~H"""
    <div class="setting setting--fixed">
      <span class="setting__label">{@setting.key}</span>
      <span class="setting__value mono">{shown(@setting)}</span>
      <p class="field-help">{@setting.summary} {@setting.consequence}</p>
    </div>
    """
  end

  defp setting(assigns) do
    ~H"""
    <form id={"setting-#{@setting.key}"} class="setting" phx-submit="save" phx-change="edit">
      <input type="hidden" name="key" value={@setting.key} />

      <label>
        {@setting.key}
        <span :if={@decided} class="setting__rung">
          in force: <span class="mono">{shown_value(@decided.value)}</span>
          <.rung rung={@decided.decided_by} />
        </span>
        <select :if={@setting.type == :enum} name="value" disabled={not @may_write}>
          <option
            :for={option <- @setting.values}
            value={option}
            selected={@value == option}
          >
            {option}
          </option>
        </select>
        <input :if={@setting.type != :enum} name="value" value={@value} disabled={not @may_write} />
      </label>

      <p class="field-help">{@setting.summary} {@setting.consequence}</p>
      <p class="micro">{source(@setting)} · {@setting.effect_description}</p>

      <p :if={@gated and @may_write and not @unlocked} class="field-help">
        Run the check below before saving this one. It decides who may use this console, and
        saving a group nobody carries locks everybody out.
      </p>

      <div class="setting__actions">
        <button type="submit" disabled={not @may_write or (@gated and not @unlocked)}>save</button>
        <button
          :if={@setting.source == :stored and @may_write}
          type="button"
          phx-click="reset"
          phx-value-key={@setting.key}
        >
          put back
        </button>
      </div>
    </form>
    """
  end

  attr(:row, :map, required: true)
  attr(:rung, :atom, required: true)

  # One rung's opinion, and whether it is the one that won. The winner is named in text
  # as well as marked with a class, because a cell that was only *styled* as the winner
  # would assert the most important thing on the page in colour alone.
  defp opinion(assigns) do
    assigns = assign(assigns, :held, held(assigns.row, assigns.rung))

    ~H"""
    <td class={["mono", won?(@row, @rung, @held) && "ladder__won"]}>
      {shown_value(@held)}<span :if={won?(@row, @rung, @held)} class="micro">
        &nbsp;· in force</span>
    </td>
    """
  end

  defp won?(row, rung, held), do: row.decided_by == rung and not is_nil(held)

  defp held(row, rung) do
    case Enum.find(row.opinions, &(&1.rung == rung)) do
      nil -> nil
      %{value: value} -> value
    end
  end

  # What the ladder makes of one setting, or `nil` where only one rung decides it.
  defp decided(assigns, key), do: Enum.find(assigns.effective, &(&1.key == key))

  # A rung with no opinion does not participate, and an em dash says so. A zero would be
  # a value somebody set.
  defp shown_value(nil), do: "—"
  defp shown_value(value) when is_boolean(value), do: if(value, do: "on", else: "off")
  defp shown_value(value), do: to_string(value)

  # One sentence each, in the answer's own order. The deployment is listed and never
  # edited here for the reason the page already gives about the issuer: a lock's keyhole
  # is not adjustable from inside the house.
  defp rung_blurb(:deployment),
    do: "Helm values and the environment. The floor, and read-only from this console."

  defp rung_blurb(:platform),
    do: "This page. A platform admin may narrow the deployment and never widen it."

  defp rung_blurb(:team),
    do: "The Teams screen. A team admin may narrow the platform and never widen it."

  defp rung_blurb(:profile),
    do: "The WorkerProfile spec: egress, MCP servers, the org mount. A platform admin's."

  defp rung_blurb(:session),
    do: "Resolved when a session is created, and recorded in the log. Never edited."

  defp rung_blurb(other), do: to_string(other)

  defp shown(%{secret: true, set: true}), do: "set · reference only, never shown"
  defp shown(%{secret: true}), do: "not set"
  defp shown(%{value: nil}), do: "not set"
  defp shown(%{value: value}), do: to_string(value)

  defp source(%{source: :stored}), do: "changed here"
  defp source(%{source: :deployed}), do: "from the deployment"
  defp source(%{source: :unset}), do: "not set"

  attr(:check, :map, required: true)

  defp checks(assigns) do
    ~H"""
    <ul class="checks">
      <li :for={check <- @check.checks} class={if check.ok, do: "checks__ok", else: "checks__bad"}>
        <span class="checks__name">{check.name}</span>
        <span class="checks__detail">{check.detail}</span>
        <span class="checks__took micro">{check.took_ms} ms</span>
      </li>
    </ul>

    <p class="field-help">
      The redirect this console sends is <code>{@check.redirect_uri || "unknown"}</code>. No
      check can prove it is registered — the provider is the only thing that knows — so if
      sign-in comes back with an error, compare it against the registration by eye.
    </p>
    """
  end
end
