defmodule Troupe.Plane.AdminCase do
  @moduledoc """
  A test that administers the plane: the sandbox, a platform-admin group, and a
  connection to the real endpoint.

  `Troupe.Plane.DataCase` with the one setting every administrative test needs, the group
  whose members are platform admins, so a test can make one with `person/2` and work out
  its actor with `Admin.actor_for/1`. The connection is for the tests that go through the
  router rather than calling `Admin` directly.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.Plane.Repo

  using do
    quote do
      import Phoenix.ConnTest
      import Troupe.Plane.DataCase

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
end
