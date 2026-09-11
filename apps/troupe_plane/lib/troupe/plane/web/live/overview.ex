defmodule Troupe.Plane.Web.Live.Overview do
  @moduledoc """
  Fleet health, sessions and spend, on one page.

  The first page an operator opens when something is wrong, so it answers the three
  questions they have in that order: is the fleet healthy, what is running, and who is
  spending. Refreshed on a timer rather than on a push, because every number here is a
  summary and a summary that updated the instant any one session moved would flicker.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @refresh_ms 2_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)
    {:ok, load(socket)}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    case Admin.overview(socket.assigns.actor) do
      {:ok, overview} -> assign(socket, overview: overview, error: nil)
      {:error, error} -> assign(socket, overview: nil, error: error.message)
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} page={:overview}>
      <p :if={@error} class="error">{@error}</p>

      <div :if={@overview}>
        <h2>Sessions</h2>
        <dl class="counts">
          <dt>active</dt>
          <dd>{@overview.sessions.active}</dd>
          <dt>dormant</dt>
          <dd>{@overview.sessions.dormant}</dd>
          <dt>read-only</dt>
          <dd>{@overview.sessions.read_only}</dd>
        </dl>

        <h2>Profiles</h2>
        <table>
          <thead>
            <tr>
              <th>profile</th>
              <th>pods</th>
              <th>healthy</th>
              <th>capacity</th>
              <th>in use</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={profile <- @overview.profiles}>
              <td><a href={"/admin/workers/#{profile.name}"}>{profile.name}</a></td>
              <td>{length(profile.pods)}</td>
              <td>{Enum.count(profile.pods, & &1.healthy)}</td>
              <td>{profile.capacity}</td>
              <td>{profile.active_sessions}</td>
            </tr>
            <tr :if={@overview.profiles == []}>
              <td colspan="5">no profiles you can see</td>
            </tr>
          </tbody>
        </table>

        <h2>Spend</h2>
        <table>
          <thead>
            <tr>
              <th>team</th>
              <th>budget</th>
              <th>spent</th>
              <th>reserved</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={team <- @overview.teams}>
              <td>{team.name}</td>
              <td>{money(team.budget_micros)}</td>
              <td>{money(team.spent_micros)}</td>
              <td>{money(team.reserved_micros)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </.shell>
    """
  end
end
