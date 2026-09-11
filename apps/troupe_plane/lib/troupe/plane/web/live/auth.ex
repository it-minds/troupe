defmodule Troupe.Plane.Web.Live.Auth do
  @moduledoc """
  Who is looking at the panel.

  A LiveView is a long-lived process, so "who is this" has to be settled when it mounts
  and not assumed afterwards. The actor is worked out from the session's subject on every
  mount — including the reconnect after a deploy — so an administrator whose role was
  taken away loses the panel at their next page rather than at their next login.

  `on_mount` rather than a plug, because a plug runs for the HTTP request that delivers
  the page and not for the socket that replaces it, and a panel authorised only by the
  former would be a panel anybody could keep open.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  alias Troupe.Plane.Admin

  @doc false
  def on_mount(:admin, _params, session, socket) do
    case actor(session) do
      nil -> {:halt, redirect(socket, to: "/admin/denied")}
      actor -> {:cont, socket |> assign(:actor, actor) |> assign(:subject, actor.subject)}
    end
  end

  def on_mount(:platform_admin, params, session, socket) do
    case on_mount(:admin, params, session, socket) do
      {:cont, socket} when socket.assigns.actor.role == :platform_admin -> {:cont, socket}
      {:cont, socket} -> {:halt, redirect(socket, to: "/admin")}
      halted -> halted
    end
  end

  defp actor(session), do: Admin.actor_for_subject(session["subject"])
end
