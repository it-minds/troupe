defmodule Troupe.Plane.ArtifactRetentionTest do
  @moduledoc """
  How long artifacts are kept (#981): `artifacts_keep_versions_days` removes versions older
  than the newest once they are that old, never the newest or the pinned one, their files
  with them unless a later version still carries one; `artifacts_keep_unopened_days` removes
  an artifact nobody opened, republished or changed for that long, whole; opening one moves
  its `opened_at`; both off, nothing goes; what the store refuses is tried again by the next
  pass and said once. `artifact.list` and `artifact.get` say when each goes.

  Against the development MinIO, as `ArtifactsTest` is.
  """

  use Troupe.Plane.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Artifacts, Audit, Harness, Repo, Settings}
  alias Troupe.Plane.Artifacts.{Artifact, Retention, Version}
  alias Troupe.Plane.Artifacts.Retention.Sweep

  @moduletag timeout: 60_000
  @day 86_400

  setup do
    Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test")

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :artifacts)
      ObjectStore.delete_prefix(ObjectStore.from_env(), "artifacts/")
    end)

    _engineering = team_with_grant("engineering", "dev", name: "engineering")
    ada = person("ada@example.test", ["engineering"])

    {:ok, doc} =
      call(ada, "artifact.publish", %{
        "title" => "Notes",
        "kind" => "markdown",
        "visibility" => "profile:dev",
        "files" => [file("index.md", "# One"), file("figure.svg", "<svg/>")]
      })

    %{store: ObjectStore.from_env(), ada: ada, doc: doc}
  end

  defp as(user), do: %{user: user, platform_admin?: Admin.actor_for(user).role == :platform_admin}
  defp call(user, method, params), do: Harness.call(method, params, as(user))

  defp file(path, body), do: %{"path" => path, "bytes" => Base.encode64(body)}

  defp keep(key, days), do: {:ok, _} = Settings.put(key, to_string(days), "root")

  defp object?(context, key) do
    match?({:ok, _body}, ObjectStore.get(context.store, "artifacts/#{context.doc["id"]}/#{key}"))
  end

  defp versions(id),
    do: Repo.all(from(v in Version, where: v.artifact_id == ^id, order_by: v.n, select: v.n))

  # Every row of an artifact as old as `days`: published, changed and opened that long ago.
  defp age(id, days) do
    then = DateTime.add(DateTime.utc_now(), -days * @day, :second)
    Repo.update_all(from(a in Artifact, where: a.id == ^id), set: [updated_at: then, opened_at: nil])
    Repo.update_all(from(v in Version, where: v.artifact_id == ^id), set: [published_at: then])
  end

  defp later(days), do: DateTime.add(DateTime.utc_now(), days * @day, :second)

  describe "old versions" do
    setup context do
      id = context.doc["id"]
      # v2 edits index.md and carries figure.svg from v1; v3 is index.md alone.
      {:ok, _} = call(context.ada, "artifact.put", %{"id" => id, "base" => 1, "files" => [file("index.md", "# Two")]})
      {:ok, _} = call(context.ada, "artifact.put", %{"id" => id, "files" => [file("index.md", "# Three")]})
      {:ok, _} = call(context.ada, "artifact.pin", %{"id" => id, "version" => 2})
      :ok
    end

    test "go once older than the period, never the newest or the pinned one, files and all", context do
      id = context.doc["id"]
      keep("artifacts_keep_versions_days", 30)
      before = Repo.get!(Artifact, id)

      {:ok, got} = call(context.ada, "artifact.get", %{"id" => id})
      assert got["retention"] == %{"versions_days" => 30, "unopened_days" => nil}
      assert got["goes_at"] == nil
      goes = Map.new(got["versions"], &{&1["n"], &1["goes_at"]})
      assert goes[3] == nil
      assert goes[2] == nil
      assert %DateTime{} = goes[1]

      # Not yet: a version a day old is kept.
      assert %{versions: 0} = Retention.sweep(later(29))
      assert versions(id) == [1, 2, 3]

      assert %{versions: 1, artifacts: 0, failed: []} = Retention.sweep(later(31))
      assert versions(id) == [2, 3]
      refute object?(context, "1/index.md")
      # v2, which is kept, carries v1's figure: that object stays.
      assert object?(context, "1/figure.svg")
      assert object?(context, "2/index.md")
      assert Repo.get!(Artifact, id).total_bytes == before.total_bytes - byte_size("# One")
      # Removing a version is nobody using the artifact.
      assert Repo.get!(Artifact, id).updated_at == before.updated_at

      assert [row] = Enum.filter(Audit.list(), &(&1.action == "artifact.version.delete"))
      assert row.actor == "system:retention"
      assert row.subject_id == id
      assert row.detail["by"] == "retention"
      assert row.detail["version"] == 1
      assert row.detail["days"] == 30
      refute Map.has_key?(row.detail, "files")

      # Again: nothing more has run out, and nothing is said twice.
      assert %{versions: 0} = Retention.sweep(later(31))

      # Unpinned, v2 goes too, and the figure only it still named with it.
      {:ok, _} = call(context.ada, "artifact.pin", %{"id" => id, "version" => nil})
      assert %{versions: 1} = Retention.sweep(later(31))
      assert versions(id) == [3]
      refute object?(context, "1/figure.svg")
      refute object?(context, "2/index.md")
      assert object?(context, "3/index.md")
    end
  end

  describe "an artifact nobody opens" do
    test "goes whole once the period has passed since it was last opened or published", context do
      id = context.doc["id"]

      {:ok, opened} =
        call(context.ada, "artifact.publish", %{
          "title" => "Read often",
          "kind" => "markdown",
          "visibility" => "profile:dev",
          "files" => [file("index.md", "# Kept")]
        })

      age(id, 40)
      age(opened["id"], 40)
      keep("artifacts_keep_unopened_days", 30)

      # Opened through the plane today: its count starts again.
      {:ok, _} = call(context.ada, "artifact.open", %{"id" => opened["id"]})

      {:ok, list} = call(context.ada, "artifact.list", %{})
      goes = Map.new(list["artifacts"], &{&1["id"], &1["goes_at"]})
      assert DateTime.compare(goes[id], DateTime.utc_now()) == :lt
      assert DateTime.diff(goes[opened["id"]], DateTime.utc_now()) in (29 * @day)..(30 * @day)

      assert %{artifacts: 1, versions: 0, failed: []} = Retention.sweep()
      assert Repo.get(Artifact, id) == nil
      assert Repo.get(Artifact, opened["id"])
      refute object?(context, "1/index.md")

      assert [row] = Enum.filter(Audit.list(), &(&1.action == "artifact.delete"))
      assert row.actor == "system:retention"
      assert row.subject_id == id
      assert row.detail["by"] == "retention"
      assert row.detail["title"] == "Notes"
      assert row.detail["days"] == 30

      assert %{artifacts: 0} = Retention.sweep()
    end

    test "is opened by artifact.open and by the artifacts host's entry page, once an hour", context do
      id = context.doc["id"]
      two_days = DateTime.add(DateTime.utc_now(), -2 * @day, :second)
      Repo.update_all(from(a in Artifact, where: a.id == ^id), set: [opened_at: two_days])

      {:ok, _} = call(context.ada, "artifact.open", %{"id" => id})
      opened = Repo.get!(Artifact, id).opened_at
      assert DateTime.diff(DateTime.utc_now(), opened) < 60

      # Within the hour, a second open writes nothing.
      {:ok, _} = call(context.ada, "artifact.open", %{"id" => id})
      assert Repo.get!(Artifact, id).opened_at == opened

      Repo.update_all(from(a in Artifact, where: a.id == ^id), set: [opened_at: two_days])
      # A file of it is not an open; its entry page is.
      {:ok, _} = Artifacts.fetch(id, :current, "figure.svg", context.ada)
      assert Repo.get!(Artifact, id).opened_at == two_days
      {:ok, _} = Artifacts.fetch(id, :current, nil, context.ada)
      assert DateTime.diff(DateTime.utc_now(), Repo.get!(Artifact, id).opened_at) < 60
    end
  end

  describe "both off" do
    test "nothing goes and no row says it will", context do
      id = context.doc["id"]
      {:ok, _} = call(context.ada, "artifact.put", %{"id" => id, "files" => [file("index.md", "# Two")]})
      age(id, 4000)

      assert %{artifacts: 0, versions: 0, failed: []} = Retention.sweep(later(4000))
      assert versions(id) == [1, 2]

      {:ok, list} = call(context.ada, "artifact.list", %{})
      assert Enum.all?(list["artifacts"], &is_nil(&1["goes_at"]))
      {:ok, got} = call(context.ada, "artifact.get", %{"id" => id})
      assert got["retention"] == %{"versions_days" => nil, "unopened_days" => nil}
      assert Enum.all?(got["versions"], &is_nil(&1["goes_at"]))
      refute Enum.any?(Audit.list(), &(&1.actor == "system:retention"))
    end
  end

  describe "a removal the store refuses" do
    test "is left, tried again by the next pass, and said once", context do
      id = context.doc["id"]
      age(id, 40)
      keep("artifacts_keep_unopened_days", 30)

      refusing = %{context.store | endpoint: "http://127.0.0.1:1"}
      Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test", store: refusing)

      log =
        capture_log(fn ->
          {:ok, pid} = Sweep.start_link(interval_ms: :timer.hours(1))
          Sandbox.allow(Repo, self(), pid)
          send(pid, :pass)
          send(pid, :pass)
          assert %{failed: failed} = :sys.get_state(pid)
          assert MapSet.member?(failed, id)

          assert Repo.get(Artifact, id)

          Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test")
          send(pid, :pass)
          assert %{failed: failed} = :sys.get_state(pid)
          assert MapSet.size(failed) == 0
          GenServer.stop(pid)
        end)

      assert Repo.get(Artifact, id) == nil
      assert length(String.split(log, "could not remove #{id}")) == 2
      assert log =~ "removed 1 artifact(s)"
    end
  end

  describe "the settings" do
    test "are a whole number of days, or 0 or off" do
      for key <- ["artifacts_keep_versions_days", "artifacts_keep_unopened_days"] do
        assert Settings.get(key) == 0
        assert {:ok, %{value: 14}} = Settings.put(key, "14", "root")
        assert Settings.get(key) == 14
        assert {:ok, %{value: 0}} = Settings.put(key, "off", "root")
        assert {:ok, %{value: 0}} = Settings.put(key, "0", "root")
        assert {:error, {:invalid, reason}} = Settings.put(key, "-3", "root")
        assert reason =~ "0 or off"
        assert {:error, {:invalid, _}} = Settings.put(key, "a fortnight", "root")
        assert {:error, {:invalid, _}} = Settings.put(key, "1.5", "root")
      end

      assert Retention.periods() == %{versions: nil, unopened: nil}
    end
  end
end
