defmodule Troupe.Plane.Web.AdminMoved do
  @moduledoc """
  Where each page of the LiveView console went.

  Its editors are the console's now (`/console`), and the addresses they had are in
  deployment notes, runbooks and bookmarks. A 404 on the page somebody was told to open is
  a worse answer than the page, so each is sent to the same place in the console: the area
  that does what the page did, and the profile or the team it named.

  On a plane deployed without the console there is nowhere to send them, and the page at
  `/admin` says how that plane is administered instead.
  """

  use Phoenix.Controller, formats: [:html]

  alias Troupe.Plane.Web.Index

  # The LiveView console's pages, by the area of the console that does what each did.
  @areas %{
    "workers" => "pods",
    "provisioners" => "hosts",
    "teams" => "teams",
    "identity" => "identity",
    "provider" => "signin",
    "sessions" => "sessions",
    "budgets" => "budgets",
    "connections" => "connections",
    "bundles" => "bundles",
    "integrations" => "integrations",
    "triggers" => "triggers",
    "review" => "runs",
    "audit" => "audit",
    "policy" => "policy",
    "settings" => "policy",
    "profile" => "profiles"
  }

  @doc "Send a page of the LiveView console to the same place in the console."
  def moved(conn, %{"page" => page} = params) do
    case {Map.fetch(@areas, page), Index.console_url()} do
      {:error, _console} -> not_found(conn)
      {{:ok, _area}, nil} -> redirect(conn, to: "/admin")
      {{:ok, area}, console} -> to(conn, console <> "#/" <> place(page, area, params["within"]))
    end
  end

  # A profile a page named is that profile's page, and a team's triggers that team's; the
  # rest are the area itself. `/admin/profile/new` is the list, where a new one is made.
  defp place("workers", _area, within) when is_binary(within), do: "profiles/" <> encode(within)
  defp place("profile", _area, "new"), do: "profiles"
  defp place("profile", _area, within) when is_binary(within), do: "profiles/" <> encode(within)
  defp place("triggers", _area, within) when is_binary(within), do: "triggers/" <> encode(within)
  defp place(_page, area, _within), do: area

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp to(conn, "/" <> _ = path), do: redirect(conn, to: path)
  defp to(conn, url), do: redirect(conn, external: url)

  defp not_found(conn), do: conn |> put_status(:not_found) |> text("not found")
end
