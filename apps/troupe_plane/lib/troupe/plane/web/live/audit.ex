defmodule Troupe.Plane.Web.Live.Audit do
  @moduledoc """
  Who changed what, with the diff.

  The page somebody opens when a thing is not as they left it. Newest first, because that
  is almost always the answer, and narrowable by actor and subject because the second
  question is "what else did they do".
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(filter: %{}) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("filter", params, socket) do
    filter =
      %{}
      |> put_present(:actor, params["actor"])
      |> put_present(:kind, params["kind"])
      |> put_present(:subject_id, params["subject_id"])

    {:noreply, socket |> assign(filter: filter) |> load()}
  end

  defp put_present(filter, _key, value) when value in [nil, ""], do: filter
  defp put_present(filter, key, value), do: Map.put(filter, key, value)

  defp load(socket) do
    case Admin.audit_list(socket.assigns.actor, Enum.to_list(socket.assigns.filter)) do
      {:ok, events} -> assign(socket, events: events, error: nil)
      {:error, error} -> assign(socket, events: [], error: error.message)
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} page={:audit}>
      <p :if={@error} class="error">{@error}</p>

      <form phx-change="filter">
        <label>actor <input name="actor" value={@filter[:actor]} /></label>
        <label>kind <input name="kind" value={@filter[:kind]} /></label>
        <label>subject <input name="subject_id" value={@filter[:subject_id]} /></label>
      </form>

      <table>
        <thead>
          <tr>
            <th>when</th>
            <th>who</th>
            <th>what</th>
            <th>to</th>
            <th>changes</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={event <- @events}>
            <td>{event.occurred_at}</td>
            <td>{event.actor}</td>
            <td>{event.action}</td>
            <td>{event.subject_id}</td>
            <td><pre>{render_detail(event.detail)}</pre></td>
          </tr>
          <tr :if={@events == []}>
            <td colspan="5">nothing recorded</td>
          </tr>
        </tbody>
      </table>
    </.shell>
    """
  end

  # A diff reads better as `field: from → to` than as JSON, and an audit page is read by
  # somebody in a hurry.
  defp render_detail(detail) when detail == %{}, do: "—"

  defp render_detail(detail) do
    Enum.map_join(detail, "\n", fn
      {field, %{"from" => from, "to" => to}} -> "#{field}: #{inspect(from)} → #{inspect(to)}"
      {field, value} -> "#{field}: #{inspect(value)}"
    end)
  end
end
