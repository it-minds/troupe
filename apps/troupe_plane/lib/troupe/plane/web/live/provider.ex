defmodule Troupe.Plane.Web.Live.Provider do
  @moduledoc """
  The identity provider: the machine on the other end of the wire, and what it may do here.

  Identity is about people — who administers, which groups have been seen, which
  credentials are not a person. This is about the connection those people arrive over,
  in the shape every tool an operator has already configured this in uses: a single
  sign-on card with the provider's values and the URLs to register at it, and a connector
  card with the URL to paste into the provider, a token that is rotated and seen once,
  when it was rotated, when the provider last synced, and one switch.

  ## The save is a check first

  The sign-in form's *save* runs `admin.provider.check` against the values in the fields
  and is refused when the provider does not stand behind them — discovery does not
  answer, calls itself something else, publishes different endpoints. *Save anyway* is
  a checkbox for the administrator who knows the provider is down. Either way a blank
  field is a field nobody changed, which is what lets the secret be edited without
  being retyped every time, and *back to the deployment* is the way everything is undone.

  ## What the card refuses to show

  The token, ever again after the notice it was minted in. `admin.scim.get` says whether
  one is set and nothing else about it, and the page renders exactly that answer, so a
  screenshot of this screen and a model reading it over MCP are looking at the same
  thing and neither is looking at a credential.

  ## The switch is off until somebody turns it on

  A plane that has been enabling teams by hand should not wake up with forty new ones
  the morning after an upgrade. On, a group the provider pushes becomes a team named
  from its display name, with the platform's defaults, audited as `scim`; off, it is a
  group on the Identity screen until an administrator enables it, which is what has
  always happened. Turning it off creates no more and deletes none.
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
       error: nil,
       deleting: false,
       resetting: false,
       scim: nil,
       provider: nil,
       drafts: %{},
       check: nil
     )
     |> load()}
  end

  # -- single sign-on -------------------------------------------------------------

  # The fields as typed, kept so a refused save does not empty the form.
  @impl Phoenix.LiveView
  def handle_event("draft", params, socket), do: {:noreply, assign(socket, drafts: fields(params))}

  # The button is not a submit, so it carries no fields of its own: the drafts the form
  # has been sending on every change are what is checked, with anything the click brought.
  def handle_event("check", params, socket) do
    drafts = Map.merge(socket.assigns.drafts, fields(params))

    case Admin.provider_check(socket.assigns.actor, drafts) do
      {:ok, check} -> {:noreply, assign(socket, drafts: drafts, check: check, flash_message: nil)}
      {:error, error} -> {:noreply, assign(socket, drafts: drafts, flash_message: describe(error))}
    end
  end

  def handle_event("save", params, socket) do
    drafts = fields(params)

    case Admin.provider_put(socket.assigns.actor, drafts, params["force"] == "true") do
      {:ok, %{changes: changes}} ->
        message =
          if map_size(changes) == 0,
            do: "Nothing changed.",
            else: "Saved: #{changes |> Map.keys() |> Enum.sort() |> Enum.join(", ")}. In force on the next sign-in."

        {:noreply,
         socket |> assign(flash_message: message, drafts: %{}, check: nil) |> load()}

      {:error, %{data: %{checks: checks}} = error} ->
        # The refusal carries the checks, so the page shows *why* rather than *no*.
        check = %{checks: checks, ok: false, candidate: %{}}
        {:noreply, assign(socket, drafts: drafts, check: check, flash_message: describe(error))}

      {:error, error} ->
        {:noreply, assign(socket, drafts: drafts, flash_message: describe(error))}
    end
  end

  def handle_event("confirm-reset", _params, socket), do: {:noreply, assign(socket, resetting: true)}

  def handle_event("reset", _params, socket) do
    case Admin.provider_reset(socket.assigns.actor) do
      {:ok, _provider} ->
        message = "Every sign-in setting is back to what this plane was deployed with."

        {:noreply,
         socket
         |> assign(flash_message: message, resetting: false, drafts: %{}, check: nil)
         |> load()}

      {:error, error} ->
        {:noreply, assign(socket, flash_message: describe(error), resetting: false)}
    end
  end

  # -- the SCIM connector ---------------------------------------------------------

  def handle_event("rotate-token", _params, socket) do
    case Admin.scim_rotate(socket.assigns.actor) do
      {:ok, %{token: token}} ->
        # The token crosses once, in the notice, and is in no page after the next event,
        # in no process state and in no table.
        message = "The connector's token, shown once — paste it into the provider now: #{token}"
        {:noreply, socket |> assign(flash_message: message, deleting: false) |> load()}

      {:error, error} ->
        {:noreply, assign(socket, flash_message: describe(error))}
    end
  end

  def handle_event("confirm-delete-token", _params, socket),
    do: {:noreply, assign(socket, deleting: true)}

  def handle_event("cancel", _params, socket),
    do: {:noreply, assign(socket, deleting: false, resetting: false)}

  def handle_event("delete-token", _params, socket) do
    case Admin.scim_delete(socket.assigns.actor, socket.assigns.scim.base_url) do
      {:ok, _scim} ->
        message = "The token is gone. Every push from the provider answers 401 until a new one is made."
        {:noreply, socket |> assign(flash_message: message, deleting: false) |> load()}

      {:error, error} ->
        {:noreply, assign(socket, flash_message: describe(error), deleting: false)}
    end
  end

  def handle_event("teams-from-groups", params, socket) do
    on? = params["teams_from_groups"] in ["true", true]

    case Admin.scim_update(socket.assigns.actor, %{"teams_from_groups" => on?}) do
      {:ok, _scim} ->
        message =
          if on?,
            do: "A group the provider pushes becomes a team now, with the platform's defaults.",
            else: "A group the provider pushes stays a group until somebody enables it."

        {:noreply, socket |> assign(flash_message: message) |> load()}

      {:error, error} ->
        {:noreply, assign(socket, flash_message: describe(error))}
    end
  end

  defp load(socket) do
    with {:ok, provider} <- Admin.provider_get(socket.assigns.actor),
         {:ok, scim} <- Admin.scim_get(socket.assigns.actor) do
      assign(socket, provider: provider, scim: scim, error: nil)
    else
      {:error, error} -> assign(socket, provider: nil, scim: nil, error: describe(error))
    end
  end

  @sign_in_fields ~w(issuer client_id client_secret authorization_endpoint device_authorization_endpoint token_endpoint scopes mcp_scope)

  defp fields(params), do: Map.take(params, @sign_in_fields)

  # What the field shows: the draft if there is one, the value otherwise, and for a secret
  # nothing at all — the placeholder says whether one is set.
  defp field_value(drafts, %{key: key} = setting) do
    case Map.fetch(drafts, key) do
      {:ok, typed} -> typed
      :error -> shown_value(setting)
    end
  end

  defp shown_value(%{secret: true}), do: ""
  defp shown_value(%{value: nil}), do: ""
  defp shown_value(%{value: list}) when is_list(list), do: Enum.join(list, " ")
  defp shown_value(%{value: value}), do: to_string(value)

  defp placeholder(%{secret: true, set: true}), do: "set — leave blank to keep it"
  defp placeholder(%{secret: true}), do: "not set"
  defp placeholder(_setting), do: "not set"

  defp source_note(%{source: :stored}), do: "changed here"
  defp source_note(%{source: :deployed}), do: "from the deployment"
  defp source_note(%{source: :unset}), do: "not set"

  defp any_stored?(provider), do: Enum.any?(provider.settings, &(&1.source == :stored))

  defp describe(%{message: message, data: %{reason: reason}}), do: "#{message}: #{reason}"
  defp describe(%{message: message}), do: message

  # One sentence per state, and the state is the plane's answer rather than this page's
  # reading of the timestamps, so the CLI and MCP say the same words about the same row.
  defp status_note(%{status: :connected, last_seen_at: at}),
    do: "connected — the provider pushed at #{at}"

  defp status_note(%{status: :quiet, last_seen_at: at}),
    do: "quiet — nothing from the provider since #{at}"

  defp status_note(%{status: :never_pushed}),
    do: "waiting — a token exists and the provider has not pushed yet"

  defp status_note(%{status: :no_token}),
    do: "off — no token anywhere, so every push answers 401"

  defp token_note(%{token_set: true, deployed_token_set: true}),
    do: "set here, and one in the deployment too; either opens the door"

  defp token_note(%{token_set: true}), do: "set here · reference only, never shown"

  defp token_note(%{deployed_token_set: true}),
    do: "from the deployment (TROUPE_SCIM_TOKEN) · rotating here adds one beside it"

  defp token_note(_scim), do: "not set"

  defp when_by(nil, _by), do: "never"
  defp when_by(at, nil), do: to_string(at)
  defp when_by(at, by), do: "#{at} by #{by}"

  defp last_sync(%{last_seen_at: nil}), do: "never"
  defp last_sync(%{last_seen_at: at, last_seen_op: op}), do: "#{at} · #{op}"

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} breakglass={@breakglass} page={:provider}>
      <h1>Identity provider</h1>
      <p class="lede">
        The machine on the other end of the wire. People and their groups are on
        <.link navigate="/admin/identity">Identity</.link>; this is the connection they arrive
        over, and what it is allowed to do here.
      </p>

      <p :if={@flash_message} class="banner" role="status">{@flash_message}</p>
      <p :if={@error} class="banner banner--breakglass" role="alert">{@error}</p>

      <section :if={@provider} class="panel" id="sign-in">
        <h2>Single sign-on</h2>
        <p class="hint">
          OpenID Connect: the authorization code flow for this console, the device grant for
          the CLI, and the same provider for both. Not SAML — there is no ACS URL and no
          metadata to upload; the three URLs below are what the provider's registration has
          to know about this plane. {@provider.known_people} person/people have arrived
          through it so far.
        </p>

        <.title_block>
          <:field label="redirect URL">
            <code>{@provider.urls.redirect || "unknown — base_url is not set"}</code>
          </:field>
          <:field label="client discovery"><code>{@provider.urls.discovery || "unknown"}</code></:field>
          <:field label="signing keys"><code>{@provider.urls.jwks || "unknown"}</code></:field>
          <:field label="MCP resource"><code>{@provider.urls.resource_metadata || "unknown"}</code></:field>
        </.title_block>

        <form
          id="sign-in-form"
          phx-change="draft"
          phx-submit="save"
          autocomplete="off"
        >
          <div :for={setting <- @provider.settings} class="setting">
            <label for={"sign-in-#{setting.key}"} class="setting__label">
              <code>{setting.key}</code>
              <span class="setting__rung micro">{source_note(setting)}</span>
            </label>
            <input
              id={"sign-in-#{setting.key}"}
              name={setting.key}
              type={if setting.secret, do: "password", else: "text"}
              value={field_value(@drafts, setting)}
              placeholder={placeholder(setting)}
              disabled={@actor.role != :platform_admin}
            />
            <p class="field-help">{setting.summary} {setting.consequence}</p>
          </div>

          <div :if={@actor.role == :platform_admin} class="setting__actions">
            <button type="button" phx-click="check">check</button>
            <button type="submit">save</button>
            <label class="toggle">
              <input type="hidden" name="force" value="false" />
              <input type="checkbox" name="force" value="true" /> save anyway, the provider is down
            </label>
          </div>
        </form>

        <ul :if={@check} class="checks" id="sign-in-checks">
          <li :for={check <- @check.checks} class={if check.ok, do: "checks__ok", else: "checks__bad"}>
            <span class="checks__name">{check.name}</span>
            <span class="checks__detail">{check.detail}</span>
            <span class="checks__took micro">{check.took_ms} ms</span>
          </li>
        </ul>

        <p class="field-help">
          A blank field is a field nobody changed. Saving runs the check first and is refused
          when the provider does not stand behind the values; a wrong save is undone below,
          and the break-glass door opens this console without any provider at all.
        </p>

        <div :if={@actor.role == :platform_admin and any_stored?(@provider)} class="setting__actions">
          <button :if={not @resetting} phx-click="confirm-reset">back to the deployment</button>
          <span :if={@resetting} class="confirm">
            Every sign-in value changed here goes, and the deployment's are read again.
            <button phx-click="reset">put them back</button>
            <button phx-click="cancel">no</button>
          </span>
        </div>
      </section>

      <section :if={@scim} class="panel" id="scim-connector">
        <h2>SCIM connector</h2>
        <p class="hint">
          How this plane learns that somebody has <em>stopped</em> being in the directory —
          before their next sign-in, which without it is the only moment it would find out.
          Point the provider's provisioning at the URL below with the token, and it pushes
          users and groups here. Nothing has to be turned on for sign-in to work; this is
          for the leaving, not the arriving.
        </p>

        <.title_block>
          <:field label="base URL">
            <code id="scim-base-url">{@scim.base_url || "unknown — base_url is not set"}</code>
          </:field>
          <:field label="status">{status_note(@scim)}</:field>
          <:field label="token">{token_note(@scim)}</:field>
          <:field label="last rotated">{when_by(@scim.rotated_at, @scim.rotated_by)}</:field>
          <:field label="last sync">{last_sync(@scim)}</:field>
        </.title_block>

        <p class="field-help">
          The provider's connection test is a <code>GET</code> on <code>Users</code> with a
          filter, and that is what <em>last sync</em> shows after it. A real change is a
          <code>PATCH</code> or a <code>POST</code>.
        </p>

        <div :if={@actor.role == :platform_admin} class="setting__actions">
          <button phx-click="rotate-token">
            {if @scim.token_set, do: "rotate the token", else: "create a token"}
          </button>
          <button :if={@scim.token_set and not @deleting} phx-click="confirm-delete-token">
            delete the token
          </button>
          <span :if={@deleting} class="confirm">
            Every push from the provider answers 401 until a new token is made{if @scim.deployed_token_set,
              do: ", except with the deployment's own token, which stays",
              else: ""}.
            <button phx-click="delete-token">delete it</button>
            <button phx-click="cancel">no</button>
          </span>
        </div>

        <p :if={@actor.role == :platform_admin} class="field-help">
          A rotated token is shown once, in the notice at the top of this page, and never
          again. Paste it into the provider before you do anything else here.
        </p>

        <form
          :if={@actor.role == :platform_admin}
          id="teams-from-groups"
          phx-change="teams-from-groups"
        >
          <label class="toggle">
            <input type="hidden" name="teams_from_groups" value="false" />
            <input
              type="checkbox"
              name="teams_from_groups"
              value="true"
              checked={@scim.teams_from_groups}
            />
            Create teams from SCIM groups
          </label>
          <p class="field-help">
            On, a group the provider pushes becomes a team named from its display name, with
            the platform's defaults, and appears on <.link navigate="/admin/teams">Teams</.link>
            with nothing granted yet. Off, it is a group on Identity until somebody enables
            it. Turning this off creates no more teams and deletes none.
          </p>
        </form>

        <p :if={@actor.role != :platform_admin} class="field-help">
          Rotating the token and the switch are a platform administrator's.
        </p>
      </section>
    </.shell>
    """
  end
end
