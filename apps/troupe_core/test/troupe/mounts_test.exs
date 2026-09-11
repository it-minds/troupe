defmodule Troupe.MountsTest do
  @moduledoc """
  The roots a session may touch, and the ones that have no meaning to it.

  The distinction worth holding on to: another team's volume is not a *forbidden* path.
  It is a path with nothing to resolve it against, which is a stronger statement and the
  one the sandbox then makes true at the kernel level.
  """

  use ExUnit.Case, async: true

  alias Troupe.Mounts

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-mounts-#{System.unique_integer([:positive])}")

    session = Path.join(base, "session")
    acme = Path.join(base, "acme")
    other = Path.join(base, "other-team")
    org = Path.join(base, "org")

    for dir <- [session, acme, other, org], do: File.mkdir_p!(dir)
    File.write!(Path.join(acme, "shared.md"), "shared")
    File.write!(Path.join(other, "secrets.md"), "not yours")
    File.write!(Path.join(org, "handbook.md"), "read me")

    on_exit(fn -> File.rm_rf!(base) end)

    mounts =
      Mounts.new([
        %{name: "session", kind: :session, root: session, mode: :rw},
        %{name: "acme", kind: :team, root: acme, mode: :ro},
        %{name: "org", kind: :org, root: org, mode: :ro}
      ])

    %{base: base, session: session, acme: acme, other: other, org: org, mounts: mounts}
  end

  describe "resolving" do
    test "a bare path is the session's, as it always was", context do
      assert {:ok, resolved, entry} = Mounts.resolve(context.mounts, "lib/thing.ex")
      assert resolved == Path.join(context.session, "lib/thing.ex")
      assert entry.kind == :session
    end

    test "session:/ names the same place explicitly", context do
      assert {:ok, a, _} = Mounts.resolve(context.mounts, "lib/thing.ex")
      assert {:ok, b, _} = Mounts.resolve(context.mounts, "session:/lib/thing.ex")
      assert a == b
    end

    test "team:<name>/ names the team volume", context do
      assert {:ok, resolved, entry} = Mounts.resolve(context.mounts, "team:acme/shared.md")
      assert resolved == Path.join(context.acme, "shared.md")
      assert entry.kind == :team
      assert entry.mode == :ro
    end

    test "org:/ names the org volume", context do
      assert {:ok, resolved, entry} = Mounts.resolve(context.mounts, "org:/handbook.md")
      assert resolved == Path.join(context.org, "handbook.md")
      assert entry.kind == :org
    end

    test "another team's volume does not resolve at all", context do
      assert {:error, {:no_such_mount, "team:other-team"}} =
               Mounts.resolve(context.mounts, "team:other-team/secrets.md")

      # And not by its real path either: a path with no mount is not a path.
      absolute = Path.join(context.other, "secrets.md")
      assert {:error, {:outside_mount, "session"}} = Mounts.resolve(context.mounts, absolute)
    end

    test "escaping a mount with .. is rejected", context do
      assert {:error, {:outside_mount, _}} = Mounts.resolve(context.mounts, "team:acme/../other-team/secrets.md")
      assert {:error, {:outside_mount, _}} = Mounts.resolve(context.mounts, "../other-team/secrets.md")
    end

    test "an absolute path stays absolute and is checked, not reinterpreted", context do
      # The bug this guards against turns /etc/passwd into <session>/etc/passwd.
      assert {:error, {:outside_mount, _}} = Mounts.resolve(context.mounts, "/etc/passwd")
      assert {:ok, _, _} = Mounts.resolve(context.mounts, Path.join(context.session, "x"))
    end

    test "a session with no org mount cannot name one", context do
      mounts =
        Mounts.new([%{name: "session", kind: :session, root: context.session, mode: :rw}])

      assert {:error, {:no_such_mount, "org"}} = Mounts.resolve(mounts, "org:/handbook.md")
    end
  end

  describe "modes" do
    test "a read-only mount refuses a write before anything is opened", context do
      assert {:ok, _, _} = Mounts.resolve(context.mounts, "team:acme/shared.md", :read)
      assert {:error, {:read_only_mount, "acme"}} = Mounts.resolve(context.mounts, "team:acme/shared.md", :write)
      assert {:error, {:read_only_mount, "org"}} = Mounts.resolve(context.mounts, "org:/handbook.md", :write)
    end

    test "the session's own root is writable", context do
      assert {:ok, _, _} = Mounts.resolve(context.mounts, "notes.md", :write)
    end

    test "a team volume granted rw is writable", context do
      mounts =
        Mounts.new([
          %{name: "session", kind: :session, root: context.session, mode: :rw},
          %{name: "acme", kind: :team, root: context.acme, mode: :rw}
        ])

      assert {:ok, _, _} = Mounts.resolve(mounts, "team:acme/shared.md", :write)
    end
  end

  describe "naming" do
    test "a path is shown by the mount it is in", context do
      assert Mounts.display(context.mounts, Path.join(context.session, "lib/a.ex")) == "session:/lib/a.ex"
      assert Mounts.display(context.mounts, Path.join(context.acme, "shared.md")) == "team:acme/shared.md"
      assert Mounts.display(context.mounts, Path.join(context.org, "handbook.md")) == "org:/handbook.md"
      assert Mounts.display(context.mounts, "/elsewhere") == "/elsewhere"
    end

    test "the table survives a round trip through its durable event", context do
      round_tripped = context.mounts |> Mounts.to_json() |> Mounts.from_json()

      assert Enum.map(round_tripped.entries, & &1.name) == Enum.map(context.mounts.entries, & &1.name)
      assert Enum.map(round_tripped.entries, & &1.mode) == [:rw, :ro, :ro]
      assert Enum.map(round_tripped.entries, & &1.kind) == [:session, :team, :org]
      assert {:ok, _, _} = Mounts.resolve(round_tripped, "team:acme/shared.md")
    end
  end
end
