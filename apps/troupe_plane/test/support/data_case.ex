defmodule Troupe.Plane.DataCase do
  @moduledoc """
  A test with a database.

  Each test runs in a transaction that is rolled back, so they are independent and can
  run concurrently. Skipped loudly when there is no database, because a test suite that
  quietly stops covering the plane is worse than one that fails.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.Plane.Repo

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Troupe.Plane.DataCase

      alias Troupe.Plane.Repo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    # Platform settings are remembered for five seconds, which is right in production and
    # wrong across a rollback: a setting written by one test and rolled back would still be
    # cached when the next one read it, and the failure would land in whichever test ran
    # within five seconds rather than in the one that caused it.
    Troupe.Plane.Settings.invalidate()
    on_exit(&Troupe.Plane.Settings.invalidate/0)

    :ok
  end

  @doc "A user in the given groups, as SCIM or a login would have left them."
  @spec person(String.t(), [String.t()]) :: Troupe.Plane.Identity.User.t()
  def person(subject, group_ids \\ []) do
    alias Troupe.Plane.Identity

    {:ok, user} =
      Identity.upsert_user(%{
        subject: subject,
        email: "#{subject}@example.test",
        display_name: subject
      })

    for id <- group_ids do
      {:ok, _} = Identity.upsert_group(%{external_id: id, display_name: id})
    end

    {:ok, _} = Identity.set_memberships(user, group_ids)
    user
  end

  @doc "An enabled team over a group, with a grant on a profile."
  @spec team_with_grant(String.t(), String.t(), keyword()) :: Troupe.Plane.Identity.Team.t()
  def team_with_grant(group_id, profile, opts \\ []) do
    alias Troupe.Plane.Identity

    {:ok, group} = Identity.upsert_group(%{external_id: group_id, display_name: group_id})
    {:ok, team} =
      Identity.enable_team(
        group,
        Map.new(Keyword.take(opts, [:name, :budget_micros, :volume_storage_class, :volume_size]))
      )
    {:ok, _} = Identity.grant(team, profile, Map.new(Keyword.take(opts, [:volume_mode])))
    team
  end
end
