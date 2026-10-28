defmodule Troupe.Plane.Web.AdminMoved do
  @moduledoc """
  Where `/admin` and each page under it went.

  The plane served its own console there once, a LiveView, and the addresses it had are
  in deployment notes, runbooks and bookmarks. A 404 on the page somebody was told to
  open is a worse answer than the page, so each is sent to the same place in the console:
  the area that does what the page did, and the profile or the team it named. `/admin`
  itself is the console's overview, and `/admin/breakglass`, which was the form the
  break-glass token was typed into, is the console's sign-in screen, where the door is
  offered now; the token itself is exchanged at `POST /auth/breakglass`.

  On a plane deployed without the console there is nowhere to send them, and `/admin`
  says instead how such a plane is administered: with `troupe admin`, over `/rpc`, or
  with the admin MCP tools, and through the same door when the identity provider cannot
  let anybody in.
  """

  import Plug.Conn

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

  @doc "`/admin`: the console's overview, or the page that says there is no console."
  @spec index(Plug.Conn.t()) :: Plug.Conn.t()
  def index(conn) do
    case Index.console_url() do
      nil -> page(conn, no_console())
      console -> redirect(conn, console <> "#/overview")
    end
  end

  @doc """
  `/admin/breakglass`: the console's sign-in screen, which offers the door.

  Answered whether or not a door is configured. Discovery already says whether one
  exists, so a redirect here tells a stranger nothing it could not read there, and the
  door itself is still a 404 where there is none.
  """
  @spec breakglass(Plug.Conn.t()) :: Plug.Conn.t()
  def breakglass(conn) do
    case Index.console_url() do
      nil -> page(conn, no_console())
      console -> redirect(conn, console)
    end
  end

  @doc "Send a page of the LiveView console to the same place in the console."
  @spec moved(Plug.Conn.t(), String.t(), String.t() | nil) :: Plug.Conn.t()
  def moved(conn, page, within) do
    case {Map.fetch(@areas, page), Index.console_url()} do
      {:error, _console} ->
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "not found")

      {{:ok, _area}, nil} ->
        redirect(conn, "/admin")

      {{:ok, area}, console} ->
        redirect(conn, console <> "#/" <> place(page, area, within))
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

  defp redirect(conn, location) do
    conn
    |> put_resp_header("location", location)
    |> put_resp_content_type("text/html")
    |> send_resp(
      302,
      ~s(<html><body>You are being <a href="#{escape(location)}">redirected</a>.</body></html>)
    )
  end

  defp page(conn, html) do
    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  # The words the front page's console door has for a plane without a console, as a page
  # of their own, with the one door that is still here. Styled by attribute and not by a
  # stylesheet: the console's stylesheets went with the console, and the page is short.
  defp no_console do
    """
    <!DOCTYPE html>
    <html lang="en"><head><meta charset="utf-8"><title>troupe</title></head>
    <body style="font: 14px/1.6 ui-monospace, monospace; padding: 2rem; max-width: 44rem;">
      <h1 style="font-size: 1rem;">This plane has no console</h1>
      <p>
        It is administered with <code>troupe admin</code>, over <code>POST /rpc</code>, or
        with the admin MCP tools at <code>POST /mcp</code>: the same methods, the same
        token, the same permissions.
      </p>
      <p>
        When the identity provider cannot let anybody in, the break-glass door is
        <code>POST /auth/breakglass</code> with the deployment's token, which
        <code>troupe admin</code> uses; <code>/.well-known/troupe</code> says whether this
        plane has one.
      </p>
      <p style="opacity: 0.75;"><a href="/">This plane</a> · <a href="/docs">What it is</a></p>
    </body></html>
    """
  end

  defp escape(value), do: value |> Plug.HTML.html_escape() |> to_string()
end
