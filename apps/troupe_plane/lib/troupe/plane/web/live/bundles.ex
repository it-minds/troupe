defmodule Troupe.Plane.Web.Live.Bundles do
  @moduledoc """
  Config bundles: what is published, what each pod is running, and rolling back.

  Rolling back is retiring: a version that is retired is one nothing new starts on, and
  the sessions already running on it are untouched. There is no "revert" that rewrites a
  version, because versions are immutable — a session pinned to v2 has to keep meaning
  what v2 meant, or its next activation would silently be a different session.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    {:ok, socket |> assign(channel: params["channel"] || "stable", flash_message: nil) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("channel", %{"channel" => channel}, socket) do
    {:noreply, socket |> assign(channel: channel) |> load()}
  end

  def handle_event("publish", %{"content" => content}, socket) do
    case Jason.decode(content) do
      {:ok, %{} = decoded} ->
        respond(socket, Admin.bundle_publish(socket.assigns.actor, socket.assigns.channel, decoded))

      _ ->
        {:noreply, assign(socket, flash_message: "that is not a JSON object")}
    end
  end

  def handle_event("retire", %{"version" => version}, socket) do
    respond(socket, Admin.bundle_retire(socket.assigns.actor, socket.assigns.channel, String.to_integer(version)))
  end

  defp respond(socket, {:ok, bundle}) do
    {:noreply, socket |> assign(flash_message: "v#{bundle.version} — #{bundle.hash}") |> load()}
  end

  defp respond(socket, {:error, error}), do: {:noreply, assign(socket, flash_message: error.message)}

  defp load(socket) do
    case Admin.bundles_list(socket.assigns.actor, socket.assigns.channel) do
      {:ok, bundles} -> assign(socket, bundles: bundles, error: nil)
      {:error, error} -> assign(socket, bundles: [], error: error.message)
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} page={:bundles}>
      <p :if={@error} class="error">{@error}</p>
      <p :if={@flash_message} class="notice">{@flash_message}</p>

      <form phx-change="channel">
        <label>channel <input name="channel" value={@channel} /></label>
      </form>

      <table>
        <thead>
          <tr>
            <th>version</th>
            <th>hash</th>
            <th>published</th>
            <th>by</th>
            <th>state</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={bundle <- @bundles} class={if bundle.retired_at, do: "neutral", else: "good"}>
            <td>v{bundle.version}</td>
            <td>{bundle.hash}</td>
            <td>{bundle.published_at}</td>
            <td>{bundle.published_by}</td>
            <td>{if bundle.retired_at, do: "retired", else: "live"}</td>
            <td>
              <button
                :if={is_nil(bundle.retired_at) and @actor.role == :platform_admin}
                phx-click="retire"
                phx-value-version={bundle.version}
              >
                retire
              </button>
            </td>
          </tr>
          <tr :if={@bundles == []}>
            <td colspan="6">nothing published on {@channel}</td>
          </tr>
        </tbody>
      </table>

      <form :if={@actor.role == :platform_admin} phx-submit="publish">
        <label>
          new version (JSON)
          <textarea name="content" rows="8">{~s({"agents": [], "skills": [], "mcp_servers": []})}</textarea>
        </label>
        <button type="submit">publish to {@channel}</button>
      </form>

      <p class="hint">
        Publishing tells every pod on this channel. Running sessions keep the version they
        started on; retiring one stops anything new starting on it and leaves those alone.
      </p>
    </.shell>
    """
  end
end
