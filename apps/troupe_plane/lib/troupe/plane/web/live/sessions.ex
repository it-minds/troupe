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
    {:ok,
     socket
     |> assign(filter: %{}, flash_message: nil, confirming: nil, effect: nil, typed: "")
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("filter", params, socket) do
    filter =
      %{}
      |> put_present(:state, params["state"])
      |> put_present(:profile, params["profile"])

    {:noreply, socket |> assign(filter: filter) |> load()}
  end

  # The count before the deed, like every other irreversible action here. Somebody erasing
  # a session is usually right about which session and often wrong about what goes with it,
  # and the third consequence — that forks survive — is the one people get backwards.
  def handle_event("confirm-erase", %{"session" => id}, socket) do
    case Admin.session_erase_preview(socket.assigns.actor, id) do
      {:ok, effect} ->
        {:noreply, assign(socket, confirming: id, effect: effect, typed: "")}

      {:error, error} ->
        {:noreply, assign(socket, flash_message: error.message, confirming: nil)}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, confirming: nil, effect: nil, typed: "")}
  end

  # What has been typed into the confirmation field, so the button can be disabled until
  # it matches. Kept in the socket rather than read at submit, because a button that looks
  # pressable and then refuses has already wasted the reader's attention.
  def handle_event("typing", %{"confirm" => typed}, socket) do
    {:noreply, assign(socket, typed: typed)}
  end

  def handle_event("erase", %{"session" => id, "confirm" => typed}, socket) do
    if typed == id do
      erase(socket, id)
    else
      # Refused here as well as disabled in the page. The dialog's rule is the same rule
      # the MCP tool applies to a model — a `confirm` that must match exactly — and a
      # check that lived only in the markup would be a check a form post walks past.
      {:noreply,
       assign(socket,
         flash_message: "that is not #{id}; nothing was erased",
         confirming: nil,
         effect: nil,
         typed: ""
       )}
    end
  end

  defp erase(socket, id) do
    case Admin.session_erase(socket.assigns.actor, id) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(
           flash_message: "erased #{id}; the tombstone keeps #{result.head_hash}",
           confirming: nil,
           effect: nil,
           typed: ""
         )
         |> load()}

      {:error, error} ->
        {:noreply,
         assign(socket, flash_message: error.message, confirming: nil, effect: nil, typed: "")}
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
    <.shell actor={@actor} breakglass={@breakglass} page={:sessions}>
      <p :if={@error} class="error">{@error}</p>
      <p :if={@flash_message} class="notice">{@flash_message}</p>

      <form id="session-filter" phx-change="filter">
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
              <button
                :if={@confirming != session.id}
                phx-click="confirm-erase"
                phx-value-session={session.id}
              >
                erase
              </button>
            </td>
          </tr>
          <tr :if={@sessions == []}>
            <td colspan="9">no sessions you can see</td>
          </tr>
        </tbody>
      </table>

      <section :if={@effect} class="panel">
        <h2>Erase {@effect.session_id}?</h2>

        <p class="hint">
          <strong>Irreversible.</strong>
          Not a delete a restore undoes. Three things happen, and the third is the one
          people expect to go the other way.
        </p>

        <ul class="checks">
          <li class="checks__bad">
            <span class="checks__name">the key is destroyed</span>
            <span class="checks__detail">
              every version of it, in the key manager. After this, no backup of object
              storage, of PostgreSQL or of any volume can recover what this session said —
              the ciphertext may survive a restore and nothing can read it.
            </span>
          </li>

          <li class="checks__bad">
            <span class="checks__name">every object version goes</span>
            <span class="checks__detail">
              the whole prefix, including prior versions in the versioned bucket, which is
              where a restore would otherwise find them.
              {bytes(@effect.object_bytes)} of objects and
              {bytes(@effect.workspace_bytes)} of workspace.
            </span>
          </li>

          <li class={if @effect.survivor_count > 0, do: "checks__ok", else: "checks__ok"}>
            <span class="checks__name">
              {@effect.survivor_count} {if @effect.survivor_count == 1,
                do: "fork survives",
                else: "forks survive"}
            </span>
            <span class="checks__detail">
              A fork is a separate session with its own key, sealed under it from the moment
              it was opened. Erasing this one leaves them readable.
              <span :if={@effect.survivor_count > 0}>
                They are {Enum.join(@effect.survivors, ", ")} — erase each one separately if
                that is what you meant.
              </span>
            </span>
          </li>
        </ul>

        <form id="erase-session" phx-submit="erase" phx-change="typing">
          <input type="hidden" name="session" value={@effect.session_id} />

          <label for="erase-session-confirm">Type the session's own identifier</label>

          <p class="field-help">
            <code>{@effect.confirm}</code>. The same rule the MCP tool applies to a model:
            a confirmation that has to match exactly, so the thing being destroyed is named
            by the person destroying it.
          </p>
          <input
            id="erase-session-confirm"
            name="confirm"
            value={@typed}
            autocomplete="off"
            spellcheck="false"
          />

          <div class="setting__actions">
            <button type="submit" disabled={@typed != @effect.confirm}>erase it</button>
            <button type="button" phx-click="cancel">no</button>
          </div>
        </form>
      </section>
    </.shell>
    """
  end
end
