defmodule Troupe.Plane.Web.Live.Settings do
  @moduledoc """
  What this plane is configured with, and which of it can be changed from here.

  The page exists because the honest answer to "where is this platform's configuration"
  used to be "in a values file somebody has, and in an environment variable, and in the
  head of whoever deployed it". Everything is on one page now, including the parts this
  console deliberately cannot change — a read-only row that says why is more use than a
  field that is missing, because a missing field reads as a feature nobody built.

  ## Two things this page does that a settings page usually does not

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
     |> assign(notice: nil, error: nil, check: nil, drafts: %{}, groups: [], settings: [])
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
      {:ok, %{groups: groups, settings: settings}} ->
        assign(socket, groups: groups, settings: settings)

      {:error, error} ->
        assign(socket, groups: [], settings: [], error: describe(error))
    end
  end

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
    <.shell actor={@actor} breakglass={@breakglass} page={:settings}>
      <h1>Settings</h1>
      <p class="lede">
        What this plane is configured with. Each field says what it does, what changes when
        you change it, and where the value it has now came from.
      </p>

      <p :if={@notice} class="banner" role="status">{@notice}</p>
      <p :if={@error} class="banner banner--breakglass" role="alert">{@error}</p>

      <p :if={@actor.role != :platform_admin} class="banner">
        <strong>This page is read-only for you.</strong>
        What a platform is configured with is a platform admin's to change, and you
        administer teams. Everything below is what is set; nothing below will save.
      </p>

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
