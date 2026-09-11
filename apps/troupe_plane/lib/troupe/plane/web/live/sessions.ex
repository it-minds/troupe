defmodule Troupe.Plane.Web.Live.Sessions do
  @moduledoc """
  Sessions, as metadata.

  What is here is what a person administering storage and retention needs: who owns it,
  what state it is in, how much it is costing in bytes, and whether somebody has pinned
  it. What is not here is anything it said — not filtered out at the edge, but absent,
  because the context this page reads from has no function that could return it.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(filter: %{}, flash_message: nil, confirming: nil) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("filter", params, socket) do
    filter =
      %{}
      |> put_present(:state, params["state"])
      |> put_present(:profile, params["profile"])

    {:noreply, socket |> assign(filter: filter) |> load()}
  end

  # Two steps, because erasure is irreversible and a misclick should not be enough.
  def handle_event("confirm-erase", %{"session" => id}, socket) do
    {:noreply, assign(socket, confirming: id)}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, confirming: nil)}

  def handle_event("erase", %{"session" => id}, socket) do
    case Admin.session_erase(socket.assigns.actor, id) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(flash_message: "erased #{id}; the tombstone keeps #{result.head_hash}", confirming: nil)
         |> load()}

      {:error, error} ->
        {:noreply, assign(socket, flash_message: error.message, confirming: nil)}
    end
  end

  defp put_present(filter, _key, value) when value in [nil, ""], do: filter
  defp put_present(filter, key, value), do: Map.put(filter, key, value)

  defp load(socket) do
    case Admin.sessions_list(socket.assigns.actor, Enum.to_list(socket.assigns.filter)) do
      {:ok, sessions} -> assign(socket, sessions: sessions, error: nil)
      {:error, error} -> assign(socket, sessions: [], error: error.message)
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} page={:sessions}>
      <p :if={@error} class="error">{@error}</p>
      <p :if={@flash_message} class="notice">{@flash_message}</p>

      <form phx-change="filter">
        <label>
          state
          <select name="state">
            <option value="">any</option>
            <option :for={state <- ~w(active dormant read_only)} value={state} selected={@filter[:state] == state}>
              {state}
            </option>
          </select>
        </label>
        <label>profile <input name="profile" value={@filter[:profile]} /></label>
      </form>

      <p class="hint">
        Metadata only. No administrative role grants access to what a session said.
      </p>

      <table>
        <thead>
          <tr>
            <th>session</th>
            <th>owner</th>
            <th>profile</th>
            <th>state</th>
            <th>seq</th>
            <th>objects</th>
            <th>workspace</th>
            <th>pinned</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={session <- @sessions}>
            <td>{session.id}</td>
            <td>{session.owner}</td>
            <td>{session.profile}</td>
            <td>{session.state}</td>
            <td>{session.last_seq}</td>
            <td>{bytes(session.object_bytes)}</td>
            <td>{bytes(session.workspace_bytes)}</td>
            <td>{if session.pinned, do: session.pinned_by || "yes", else: "—"}</td>
            <td>
              <button :if={@confirming != session.id} phx-click="confirm-erase" phx-value-session={session.id}>
                erase
              </button>
              <span :if={@confirming == session.id}>
                irreversible —
                <button phx-click="erase" phx-value-session={session.id}>erase it</button>
                <button phx-click="cancel">no</button>
              </span>
            </td>
          </tr>
          <tr :if={@sessions == []}>
            <td colspan="9">no sessions you can see</td>
          </tr>
        </tbody>
      </table>
    </.shell>
    """
  end
end
