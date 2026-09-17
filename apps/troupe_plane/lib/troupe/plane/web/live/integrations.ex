defmodule Troupe.Plane.Web.Live.Integrations do
  @moduledoc """
  What this plane talks to that is not a person.

  Three lists, each answering a question that has been answered by reading a values file
  and asking somebody who remembers.

  **Servers on more than one profile** are the organisation's integration rather than any
  one profile's: connected once, credentialed once, retired once. The profiles that carry
  each one are the useful column, because they are the blast radius of retiring it.

  **Every host anything here dials**, checked against the same function a pod's
  NetworkPolicy is generated from. A host in a bundle the policy refuses is a tool that
  fails at the moment somebody first uses it, and this is where that becomes visible
  beforehand rather than afterwards.

  **Notification targets**, checked again rather than trusted. A target that passed when it
  was saved and does not now is precisely what somebody needs told — and the rule it is
  held to is the one LangGraph shipped an advisory about in 2026: absolute, naming a host,
  and not loopback.

  ## Read-only, and that is the decision rather than the shortcut

  The allowlist is trustworthy because it is generated from what each component declares it
  dials. An allowlist edited in two places is an allowlist nobody trusts, so this page names
  where each host came from and leaves the editing to the thing that declared it.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(servers: [], profile_servers: [], egress: [], notify: [], error: nil)
     |> load()}
  end

  defp load(socket) do
    case Admin.integrations(socket.assigns.actor) do
      {:ok, answer} ->
        assign(socket,
          servers: answer.servers,
          profile_servers: answer.profile_servers,
          egress: answer.egress,
          notify: answer.notify,
          error: nil
        )

      {:error, error} ->
        assign(socket,
          servers: [],
          profile_servers: [],
          egress: [],
          notify: [],
          error: describe(error)
        )
    end
  end

  defp describe(%{message: message, data: %{reason: reason}}), do: "#{message}: #{reason}"
  defp describe(%{message: message}), do: message

  defp credential(%{credential_mode: "person", credential_ref: slot}),
    do: "each person's own, in slot #{slot}"

  defp credential(%{credential_ref: ref}) when is_binary(ref) and ref != "",
    do: "a Secret named #{ref}"

  defp credential(_server), do: "none"

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} breakglass={@breakglass} page={:integrations}>
      <h1>Integrations</h1>
      <p class="lede">
        What this plane talks to that is not a person, and whether the cluster's policy
        lets it. Read-only: the allowlist is trustworthy because it is generated from what
        each component declares it dials, and one edited in two places is one nobody trusts.
      </p>

      <p :if={@error} class="banner banner--breakglass" role="alert">{@error}</p>

      <section class="panel">
        <h2>Servers more than one profile carries</h2>
        <p class="hint">
          An organisation's integration rather than one profile's. The profiles are the
          blast radius of retiring it.
        </p>

        <p :if={@servers == []} class="empty">
          No server is carried by two profiles. Everything below belongs to one.
        </p>

        <div :if={@servers != []} class="scroller">
          <table>
            <thead>
              <tr>
                <th>server</th>
                <th>url</th>
                <th>credential</th>
                <th>carried by</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={server <- @servers}>
                <th scope="row">{server.name}</th>
                <td>{server.url}</td>
                <td>{credential(server)}</td>
                <td>{Enum.join(server.profiles, ", ")}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <h3 :if={@profile_servers != []}>And one profile each</h3>
        <ul :if={@profile_servers != []} class="checks">
          <li :for={server <- @profile_servers} class="checks__ok">
            <span class="checks__name">{server.name}</span>
            <span class="checks__detail">
              {server.url} · {credential(server)} · on {Enum.join(server.profiles, ", ")}
            </span>
          </li>
        </ul>
      </section>

      <section class="panel">
        <h2>Every host anything here dials</h2>
        <p class="hint">
          Checked against the same function the cluster's NetworkPolicy is generated from. A
          host the policy refuses is a tool that fails the first time somebody uses it — the
          repair is made where the host was declared, which is the column beside it.
        </p>

        <div class="scroller">
          <table>
            <thead>
              <tr>
                <th>host</th>
                <th>declared by</th>
                <th>the policy</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={entry <- @egress}>
                <th scope="row">{entry.host}</th>
                <td>{entry.from}</td>
                <td>
                  <span :if={entry.allowed}>allowed</span>
                  <span :if={not entry.allowed} class="rung rung--deployment">refused</span>
                </td>
              </tr>
              <tr :if={@egress == []}>
                <td colspan="3" class="none">
                  Nothing here dials anything outside the cluster.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="panel">
        <h2>Where outcomes are sent</h2>
        <p class="hint">
          A trigger may post its outcome somewhere. The target must name a host and must not
          be loopback: a relative target resolved against this plane's own address is the
          advisory LangGraph shipped in 2026, and the check is cheaper to have than to
          explain. Checked again here rather than trusted — one that passed when it was
          saved and does not now is what somebody needs told.
        </p>

        <p :if={@notify == []} class="empty">No trigger sends its outcome anywhere.</p>

        <ul :if={@notify != []} class="checks">
          <li
            :for={target <- @notify}
            class={if target.refusal, do: "checks__bad", else: "checks__ok"}
          >
            <span class="checks__name">{target.team}/{target.trigger}</span>
            <span class="checks__detail">
              {target.url}
              <span :if={target.refusal}>— would be refused now: {target.refusal}</span>
            </span>
          </li>
        </ul>
      </section>
    </.shell>
    """
  end
end
