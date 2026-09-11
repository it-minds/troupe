defmodule Troupe.Plane.PanelCase do
  @moduledoc """
  A test that drives the admin panel the way a browser does.

  `Phoenix.LiveViewTest` against the real endpoint and the real routes, because the parts
  of a panel that break are the parts a unit test of the LiveView module would skip: the
  mount that decides who you are, the session the socket carries, the redirect a person
  with no role gets.

  Signing in is done by putting a subject in the session — the same thing the OIDC
  callback does, and the only thing it puts there. The role is derived on every mount, so
  a test that signs in as somebody who is not an administrator gets what they would get.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.Plane.Repo

  using do
    quote do
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Troupe.Plane.DataCase
      import Troupe.Plane.PanelCase

      alias Troupe.Plane.Repo

      @endpoint Troupe.Plane.Web.Endpoint
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  A connection carrying a signed-in subject.

  Exactly what the OIDC callback leaves behind: a subject, and nothing about what they
  may do.
  """
  @spec sign_in(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def sign_in(conn, subject) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:subject, subject)
  end
end
