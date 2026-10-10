defmodule Troupe.Watch.WatchSessionTest do
  @moduledoc """
  Watch mode wired to a real session: turning it on and off, and what a client is told of
  it (Decision 844). Where a trigger goes is `Troupe.Watch.WatchBranchTest`.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Gitignore
  alias Troupe.Session.{Files, Watcher}

  # Reading the ignore rules walks the whole workspace; in a home directory that took
  # minutes, inside `session.create`, for rules only watching uses (#231).
  test "a session that is not watching starts without reading the ignore rules", context do
    write_file(context, ".gitignore", "secret/\n")
    %{session: session} = start_session(context, steps: [{:text, "hi"}])

    watcher = Registry.watcher_pid(session.id)
    assert %Watcher{ignore: nil} = :sys.get_state(watcher)
    assert %Files{ignore: nil} = :sys.get_state(GenServer.whereis(Registry.files(session.id)))

    # Watching reads them, and applies them.
    assert {:ok, _backend} = Troupe.watch(session.id, true)
    assert %Watcher{ignore: %Gitignore{} = ignore} = :sys.get_state(watcher)
    assert Gitignore.ignored?(ignore, "secret/key.txt")
    assert {:ok, :off} = Troupe.watch(session.id, false)
  end

  test "watch reports which backend it selected and can be toggled", context do
    %{session: session} = start_session(context, steps: [{:text, "hi"}])

    assert Watcher.backend(session.id) == :off
    assert {:ok, backend} = Troupe.watch(session.id, true)
    assert backend in [:native, :poll]
    assert Watcher.backend(session.id) == backend
    assert {:ok, :off} = Troupe.watch(session.id, false)
  end

  # D106: no client could ask whether a session watches, so a status line showed what that
  # client last set.
  test "a client hears watch go on and off, and the workspace says which session watches",
       context do
    %{session: session} = start_session(context, steps: [{:text, "hi"}])
    Troupe.subscribe(session.id)
    root = session.workspace.root_real

    assert Troupe.watch_state(root) == %{enabled: false, backend: :off, session_id: nil}

    assert {:ok, backend} = Troupe.set_watch(root, true)
    changed = await_event(session.id, :watch_changed)
    assert changed.data == %{"enabled" => true, "backend" => Atom.to_string(backend)}
    assert Troupe.watch_state(root) == %{enabled: true, backend: backend, session_id: session.id}

    # Asked again by the session that watches, it is answered as it stands; and the same
    # directory spelled another way is the same workspace.
    assert {:ok, ^backend} = Troupe.set_watch(root, true, session.id)
    other_spelling = Path.join([root, "..", Path.basename(root)])
    assert Troupe.watch_state(other_spelling).session_id == session.id

    assert {:ok, :off} = Troupe.set_watch(root, false)

    assert await_event(session.id, :watch_changed).data == %{
             "enabled" => false,
             "backend" => "off"
           }

    assert Troupe.watch_state(root).enabled == false
  end

  # A branch a trigger starts works in the same checkout, so the workspace has two sessions:
  # watch belongs to the one that is no branch, and off turns off whichever watches.
  test "with a branch in the checkout, watch goes to the session that is no branch", context do
    %{session: session} = start_session(context, steps: [{:text, "hi"}])
    %{session: branch} = start_session(context, parent: session.id, steps: [])
    _ = :sys.get_state(Troupe.Sessions.Index)
    root = session.workspace.root_real

    assert {:ok, _backend} = Troupe.set_watch(root, true)
    assert Watcher.enabled?(session.id)
    refute Watcher.enabled?(branch.id)
    assert {:error, :already_watching} = Troupe.set_watch(root, true, branch.id)

    assert {:ok, :off} = Troupe.set_watch(root, false)
    refute Watcher.enabled?(session.id)

    # Named, the branch may watch, and off still finds it.
    assert {:ok, _backend} = Troupe.set_watch(root, true, branch.id)
    assert Troupe.watch_state(root).session_id == branch.id
    assert {:ok, :off} = Troupe.set_watch(root, false)
    refute Watcher.enabled?(branch.id)
  end

  test "a pod's session does not watch, whatever its config says", context do
    %{session: session} =
      start_session(context, kind: :team, config_overrides: [watch: true], steps: [])

    refute Watcher.enabled?(session.id)
    assert {:error, :not_local} = Troupe.watch(session.id, true)
    refute Watcher.enabled?(session.id)
  end
end
