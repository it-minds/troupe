defmodule Troupe.Tools.PublishTest do
  @moduledoc """
  Copying between the session's workspace and a shared volume.

  Every copy that crosses is a durable event carrying the source, the destination and
  the hash, so somebody looking at a team volume months later can find the session that
  put a file there and check it is still the same bytes. And both tools ask by default,
  because a copy onto a shared volume is visible to people who cannot see what led to
  it.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Mounts
  alias Troupe.Tools.{Import, Publish}
  alias Troupe.Workspace

  setup context do
    shared = Path.join(context.base, "acme")
    readonly = Path.join(context.base, "org")
    File.mkdir_p!(shared)
    File.mkdir_p!(readonly)
    File.write!(Path.join(shared, "design.md"), "the team's design")
    File.write!(Path.join(readonly, "handbook.md"), "the org handbook")

    Map.merge(context, %{shared: shared, readonly: readonly})
  end

  test "asks by default, both ways" do
    assert Publish.default_permission() == :ask
    assert Import.default_permission() == :ask
  end

  test "publishing records source, destination and hash", context do
    session = start_session(context, mounts: mounts(context, :rw))
    Troupe.subscribe(session.session.id)

    write_file(context, "notes.md", "worth sharing")

    assert {:ok, message} =
             Publish.run(
               %{"source" => "notes.md", "destination" => "team:acme/notes/shared.md"},
               ctx(session, context, :rw)
             )

    assert message =~ "Published session:/notes.md to team:acme/notes/shared.md"
    assert File.read!(Path.join(context.shared, "notes/shared.md")) == "worth sharing"

    event = await_event(session.session.id, :published)
    assert event.data["source"] == "session:/notes.md"
    assert event.data["destination"] == "team:acme/notes/shared.md"
    assert event.data["direction"] == "out"
    assert event.data["bytes"] == byte_size("worth sharing")

    expected = "sha256:" <> (:sha256 |> :crypto.hash("worth sharing") |> Base.encode16(case: :lower))
    assert event.data["hash"] == expected
  end

  test "importing records the copy coming the other way", context do
    session = start_session(context, mounts: mounts(context, :ro))
    Troupe.subscribe(session.session.id)

    assert {:ok, message} =
             Import.run(
               %{"source" => "team:acme/design.md", "destination" => "reference/design.md"},
               ctx(session, context, :ro)
             )

    assert message =~ "Imported team:acme/design.md to session:/reference/design.md"
    assert read_file(context, "reference/design.md") == "the team's design"

    event = await_event(session.session.id, :published)
    assert event.data["direction"] == "in"
    assert event.data["source"] == "team:acme/design.md"
    assert event.data["destination"] == "session:/reference/design.md"
  end

  test "publishing to a read-only volume is refused before anything is written", context do
    session = start_session(context, mounts: mounts(context, :ro))
    write_file(context, "notes.md", "worth sharing")

    assert {:error, {:read_only_mount, "acme"}} =
             Publish.run(
               %{"source" => "notes.md", "destination" => "team:acme/notes.md"},
               ctx(session, context, :ro)
             )

    refute File.exists?(Path.join(context.shared, "notes.md"))

    assert {:error, {:read_only_mount, "org"}} =
             Publish.run(
               %{"source" => "notes.md", "destination" => "org:/notes.md"},
               ctx(session, context, :ro)
             )
  end

  test "a copy that does not cross is refused: that is what write_file is for", context do
    session = start_session(context, mounts: mounts(context, :rw))
    write_file(context, "notes.md", "worth sharing")

    assert {:error, message} =
             Publish.run(
               %{"source" => "notes.md", "destination" => "copy.md"},
               ctx(session, context, :rw)
             )

    assert message =~ "publish copies from session:/ to a shared volume"
  end

  test "another team's volume cannot be published to", context do
    elsewhere = Path.join(context.base, "other-team")
    File.mkdir_p!(elsewhere)

    session = start_session(context, mounts: mounts(context, :rw))
    write_file(context, "notes.md", "worth sharing")

    assert {:error, {:no_such_mount, "team:other-team"}} =
             Publish.run(
               %{"source" => "notes.md", "destination" => "team:other-team/notes.md"},
               ctx(session, context, :rw)
             )

    assert File.ls!(elsewhere) == []
  end

  # -- helpers ----------------------------------------------------------------

  defp mounts(context, mode) do
    Mounts.new([
      %{name: "session", kind: :session, root: context.workspace, mode: :rw},
      %{name: "acme", kind: :team, root: context.shared, mode: mode},
      %{name: "org", kind: :org, root: context.readonly, mode: :ro}
    ])
  end

  defp ctx(session, context, mode) do
    %Troupe.Tool.Ctx{
      session_id: session.session.id,
      agent_path: ["root"],
      workspace: Workspace.with_mounts(session.session.workspace, mounts(context, mode)),
      call_id: "call-1",
      agent_pid: self()
    }
  end
end
