defmodule Troupe.Plane.Web.Live.Connections do
  @moduledoc """
  Who has connected a personal credential to which server — and whose identity a session
  carries.

  The screen exists to make one thing visible that people otherwise discover the hard way:
  **a session has one identity.** A person-mode server reaches out as the session's
  *owner*, fixed when the session was activated. Two people attached to one session are two
  actors behind one subject, and the answer to "whose credential made that call" is the
  owner's, not whoever typed.

  So the sessions panel prints two names per row rather than one field: the credential's
  owner and whoever else may be driving. A single name there would be the more comfortable
  design and would be the thing somebody is surprised by later.

  ## What an administrator cannot do here, said where they would look

  Read a credential, and remove one. Not as a permission this screen declines to exercise —
  there is no method for either, and the plane's key manager policy has metadata and
  nothing on the data path. An administrator retires the server from the bundle; the
  credential stays the person's. The page says so beside the list of who has connected,
  because that is where somebody would otherwise start looking for the button.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(servers: [], sessions: [], readable: true, error: nil)
     |> load()}
  end

  defp load(socket) do
    case Admin.connections(socket.assigns.actor, nil) do
      {:ok, answer} ->
        assign(socket,
          servers: answer.servers,
          sessions: answer.sessions,
          readable: answer.credentials_readable,
          error: nil
        )

      {:error, error} ->
        assign(socket, servers: [], sessions: [], readable: true, error: describe(error))
    end
  end

  defp describe(%{message: message, data: %{reason: reason}}), do: "#{message}: #{reason}"
  defp describe(%{message: message}), do: message

  defp connected(server), do: Enum.filter(server.people, & &1.connected)
  defp unconnected(server), do: Enum.reject(server.people, & &1.connected)

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} breakglass={@breakglass} page={:connections}>
      <h1>Connections</h1>
      <p class="lede">
        A person-mode server reaches out with a credential its user put in the key manager
        themselves. This is everything the plane is allowed to know about that, which is
        deliberately very little: whether a slot has been filled, and never what is in it.
      </p>

      <p :if={@error} class="banner banner--breakglass" role="alert">{@error}</p>

      <p :if={@servers == []} class="empty">
        No bundle on the profiles you administer carries a person-mode server, so nobody has
        a credential here to connect.
      </p>

      <section :for={server <- @servers} class="panel">
        <h2>{server.name}</h2>
        <p class="hint">
          Slot <code>{server.slot}</code>, on {Enum.join(server.profiles, ", ")}. The value
          lives in the key manager under each person, at a path the plane's own policy
          cannot read.
        </p>

        <h3 :if={connected(server) != []}>Connected</h3>
        <ul :if={connected(server) != []} class="checks">
          <li :for={person <- connected(server)} class="checks__ok">
            <span class="checks__name">{person.subject}</span>
            <span class="checks__detail">
              {person.display_name || "—"} — has put something in this slot. What, and when
              it was last changed, is theirs.
            </span>
          </li>
        </ul>

        <p :if={connected(server) == []} class="empty">
          Nobody has connected this one yet. A session that reaches it will be refused by
          the server rather than by Troupe.
        </p>

        <h3 :if={unconnected(server) != []}>Not connected</h3>
        <ul :if={unconnected(server) != []} class="checks">
          <li :for={person <- unconnected(server)} class="checks__bad">
            <span class="checks__name">{person.subject}</span>
            <span class="checks__detail">
              nothing in this slot, or the key manager could not be asked. Both lead to the
              same next step, which is theirs to take.
            </span>
          </li>
        </ul>

        <p :if={not @readable} class="field-help">
          <strong>You cannot read or remove any of these.</strong>
          There is no method for either — not a permission this screen declines to use. You
          can retire {server.name} from the bundle, and the credential stays the person's.
        </p>
      </section>

      <section :if={@sessions != []} class="panel">
        <h2>Whose identity each session carries</h2>
        <p class="hint">
          <strong>A session has one identity.</strong>
          Calls go out as the owner, fixed when the session was activated — so two people
          attached are two actors behind one subject, and a call made while somebody else
          was driving is still the owner's credential.
        </p>

        <div class="scroller">
          <table>
            <thead>
              <tr>
                <th>session</th>
                <th>team</th>
                <th>profile</th>
                <th>calls go out as</th>
                <th>state</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={session <- @sessions}>
                <th scope="row">{session.id}</th>
                <td>{session.team}</td>
                <td>{session.profile}</td>
                <td>{session.owner}</td>
                <td>{session.state}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </.shell>
    """
  end
end
