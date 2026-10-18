defmodule Troupe.GitTest do
  @moduledoc """
  #529 (Decision 833): the `git` Troupe runs for itself in a workspace runs outside the
  sandbox, and git honours settings in the repository's own `.git`, some of which run a
  command. A session's agent can write there, so none of them may run through `git_read`,
  the project brief or the worktree check; a repository whose git directory is somewhere
  else is not read; and the file tools do not write under `.git`.

  Each command-running setting here names a script that leaves a marker, so "did not
  run" is a file that is not there.
  """

  use ExUnit.Case, async: true

  alias Troupe.Memory.Facts
  alias Troupe.{Onboard, Workspace, Worktree}
  alias Troupe.Session.Memory
  alias Troupe.Tool.{Ctx, Result}
  alias Troupe.Tools.{EditFile, GitRead, WriteFile}

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-git-#{System.unique_integer([:positive])}")
    root = Path.join(base, "ws")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(base) end)

    commit!(root, %{"README.md" => "# r\n", "a.bin" => "one\n"})

    # Leaves its arguments in the marker and passes its input through, so as a filter or a
    # textconv it changes nothing but the marker.
    script = Path.join(base, "mark.sh")
    marker = Path.join(base, "marker")
    File.write!(script, "#!/bin/sh\necho \"$*\" >> '#{marker}'\ncat\n")
    File.chmod!(script, 0o755)

    {:ok, workspace} = Workspace.new(root)

    ctx = %Ctx{
      session_id: "s-#{System.unique_integer([:positive])}",
      agent_path: ["root"],
      workspace: workspace,
      call_id: "call_1",
      agent_pid: self(),
      config: %Troupe.Config{}
    }

    %{base: base, root: root, script: script, marker: marker, ctx: ctx}
  end

  describe "a repository whose core.fsmonitor runs a command" do
    setup c do
      git!(c.root, ["config", "core.fsmonitor", "#{c.script} fsmonitor"])
      File.write!(Path.join(c.root, "README.md"), "# r\nchanged\n")
      :ok
    end

    test "does not run it through git_read", c do
      assert {:ok, status} = GitRead.run(%{"op" => "status"}, c.ctx)
      assert status =~ " M README.md"
      assert {:ok, diff} = GitRead.run(%{"op" => "diff"}, c.ctx)
      assert diff =~ "+changed"
      refute File.exists?(c.marker), "git_read ran: #{marker(c)}"
    end

    test "does not run it through the project brief", c do
      # The brief's HEAD, stamped as a librarian's run stamps it and read back (the file count
      # it was stamped with too is gone, Decision 838), and whether git tracks an anchor, on
      # the way in and on the way back (Decision 854).
      assert {:ok, _} =
               Facts.put(c.root, %{kind: "overview", claim: "a repository"}, %{by: "librarian"})

      assert {:ok, %{"status" => "current"}} =
               Facts.put(
                 c.root,
                 %{kind: "layout", claim: "a readme", anchors: ["README.md"]},
                 %{}
               )

      assert :ok = Memory.checked(c.root)
      assert [_, _] = Facts.list(c.root)
      assert Memory.status(c.root, nil) == :fresh
      assert %{head: head, files: nil} = Memory.brief(c.root)
      assert is_binary(head)
      refute File.exists?(c.marker), "the brief ran: #{marker(c)}"
    end

    test "does not run it through the worktree check", c do
      File.mkdir_p!(Path.join(c.root, ".troupe/agents"))
      File.write!(Path.join(c.root, ".troupe/agents/a.md"), "---\nname: a\n---\nA.\n")
      # The test's own git, which would run it.
      git!(c.root, ["-c", "core.fsmonitor=false", "add", ".troupe"])
      git!(c.root, ["-c", "core.fsmonitor=false", "commit", "-q", "-m", "agents"])
      refute File.exists?(c.marker)

      assert Worktree.committed(c.root, ".troupe/agents") == MapSet.new([".troupe/agents/a.md"])
      refute File.exists?(c.marker), "the worktree check ran: #{marker(c)}"
    end
  end

  describe "a repository whose own config runs other commands" do
    test "a clean filter, a hook, textconv and an external diff do not run", c do
      # The second filter's name is one a `-c name=value` would cut short.
      File.write!(
        Path.join(c.root, ".gitattributes"),
        "*.md filter=mark\n*.bin diff=mark\n*.txt filter=a=b'c\n"
      )

      File.write!(Path.join(c.root, "w.txt"), "w\n")
      git!(c.root, ["add", ".gitattributes", "w.txt"])
      git!(c.root, ["commit", "-q", "-m", "attributes"])

      git!(c.root, ["config", "filter.mark.clean", "#{c.script} clean"])
      git!(c.root, ["config", "filter.mark.process", "#{c.script} process"])
      git!(c.root, ["config", "filter.a=b'c.clean", "#{c.script} clean a=b'c"])
      git!(c.root, ["config", "diff.mark.textconv", "#{c.script} textconv"])
      git!(c.root, ["config", "diff.mark.command", "#{c.script} external-diff"])
      hooks = Path.join(c.root, ".git/hooks")
      File.mkdir_p!(hooks)

      for hook <- ["post-index-change", "reference-transaction"] do
        File.write!(Path.join(hooks, hook), "#!/bin/sh\n#{c.script} hook #{hook} </dev/null\n")
        File.chmod!(Path.join(hooks, hook), 0o755)
      end

      # A file whose stat changed and content did not: status hashes it, through the filter.
      File.touch!(Path.join(c.root, "README.md"), System.os_time(:second) + 5)
      File.touch!(Path.join(c.root, "w.txt"), System.os_time(:second) + 5)
      File.write!(Path.join(c.root, "a.bin"), "two\n")

      assert {:ok, status} = GitRead.run(%{"op" => "status"}, c.ctx)
      assert status =~ " M a.bin"
      assert {:ok, diff} = GitRead.run(%{"op" => "diff"}, c.ctx)
      assert diff =~ "-one\n+two"
      assert {:ok, show} = GitRead.run(%{"op" => "show", "ref" => "HEAD~1"}, c.ctx)
      assert show =~ "+one"
      assert {:ok, _log} = GitRead.run(%{"op" => "log"}, c.ctx)

      refute File.exists?(c.marker), "git_read ran: #{marker(c)}"
    end
  end

  describe "a repository somewhere else" do
    setup c do
      other = Path.join(c.base, "other")
      File.mkdir_p!(other)
      commit!(other, %{"secret.txt" => "the other workspace's\n"}, "the other workspace's commit")
      %{other: other}
    end

    test "a .git naming another checkout's git directory as its common one is not read", c do
      forged = Path.join(c.base, "forged")
      File.mkdir_p!(forged)

      forgeries = [
        # a `.git` file naming a git directory whose `commondir` is the other checkout's
        fn ws ->
          gitdir = Path.join(ws, "gitdir")
          File.mkdir_p!(gitdir)
          File.write!(Path.join(gitdir, "HEAD"), "ref: refs/heads/main\n")
          File.write!(Path.join(gitdir, "commondir"), Path.join(c.other, ".git") <> "\n")
          File.write!(Path.join(ws, ".git"), "gitdir: #{gitdir}\n")
        end,
        # a `.git` directory with such a `commondir` in it
        fn ws ->
          File.mkdir_p!(Path.join(ws, ".git"))
          File.write!(Path.join(ws, ".git/HEAD"), "ref: refs/heads/main\n")
          File.write!(Path.join(ws, ".git/commondir"), Path.join(c.other, ".git") <> "\n")
        end,
        # a `.git` file naming the other checkout's git directory itself
        fn ws -> File.write!(Path.join(ws, ".git"), "gitdir: #{Path.join(c.other, ".git")}\n") end
      ]

      for {forge, n} <- Enum.with_index(forgeries) do
        ws = Path.join(forged, "#{n}")
        File.mkdir_p!(ws)
        forge.(ws)

        # git itself is taken in.
        {log, 0} = System.cmd("git", ["log", "--format=%s"], cd: ws)
        assert log =~ "the other workspace's commit"

        {:ok, workspace} = Workspace.new(ws)
        ctx = %{c.ctx | workspace: workspace}

        for op <- ["log", "status", "show", "branch"] do
          assert {:error, message} = GitRead.run(%{"op" => op}, ctx)
          assert message =~ "git was not run: this workspace's .git names #{c.other}/.git"
          refute message =~ "the other workspace's commit"
        end

        assert {:ok, _} =
                 Facts.put(ws, %{kind: "overview", claim: "forged #{n}"}, %{by: "librarian"})

        assert Memory.checked(ws) == :ok
        assert Memory.brief(ws).head == nil
      end
    end

    test "objects reached through alternates or a link out of the checkout are not read", c do
      # #538: git reads objects wherever `objects/info/alternates` or a link in `objects`
      # leads, so the other checkout's commit would show as the workspace's own.
      secret = c.other |> git!(["rev-parse", "HEAD"]) |> String.trim()
      other_objects = Path.join(c.other, ".git/objects")
      fan_out = String.slice(secret, 0, 2)

      # The same objects, packed, for a link to a pack.
      packed = Path.join(c.base, "packed.git")
      git!(c.base, ["clone", "-q", "--bare", "--no-local", c.other, packed])
      [pack] = Path.wildcard(Path.join(packed, "objects/pack/*.pack"))

      escapes = [
        alternates: fn objects ->
          File.write!(Path.join(objects, "info/alternates"), "# a comment\n#{other_objects}\n")
        end,
        relative_alternates: fn objects ->
          relative = Path.relative_to(other_objects, c.base) |> then(&"../../../../#{&1}")
          File.write!(Path.join(objects, "info/alternates"), relative <> "\n")
        end,
        # quoted as git quotes a path, with an octal escape for the `o` of `other`
        quoted_alternates: fn objects ->
          quoted = String.replace(other_objects, "/other/", "/\\157ther/")
          File.write!(Path.join(objects, "info/alternates"), ~s("#{quoted}"\n))
        end,
        # an alternate inside the checkout, whose own alternates lead out
        alternates_through_one_inside: fn objects ->
          inner = Path.expand("../../vendor", objects)
          File.mkdir_p!(inner)
          commit!(inner, %{"v.txt" => "v\n"}, "vendored")
          inner_objects = Path.join(inner, ".git/objects")
          File.write!(Path.join(inner_objects, "info/alternates"), other_objects <> "\n")
          File.write!(Path.join(objects, "info/alternates"), inner_objects <> "\n")
        end,
        objects_link: fn objects ->
          File.rm_rf!(objects)
          File.ln_s!(other_objects, objects)
        end,
        fan_out_link: fn objects ->
          File.rm_rf!(Path.join(objects, fan_out))
          File.ln_s!(Path.join(other_objects, fan_out), Path.join(objects, fan_out))
        end,
        pack_link: fn objects ->
          for file <- [pack, String.replace_suffix(pack, ".pack", ".idx")],
              do: File.ln_s!(file, Path.join([objects, "pack", Path.basename(file)]))
        end
      ]

      for {key, escape} <- escapes, name = Atom.to_string(key) do
        ws = Path.join([c.base, "escapes", name])
        File.mkdir_p!(ws)
        commit!(ws, %{"mine.txt" => "mine\n"}, "the workspace's own commit")
        escape.(Path.join(ws, ".git/objects"))

        # git itself is taken in.
        {shown, 0} = System.cmd("git", ["cat-file", "commit", secret], cd: ws)
        assert shown =~ "the other workspace's commit", "#{name}: the escape did not work"

        {:ok, workspace} = Workspace.new(ws)
        ctx = %{c.ctx | workspace: workspace}

        for args <- [%{"op" => "show", "ref" => secret}, %{"op" => "log", "ref" => secret}] do
          assert {:error, message} = GitRead.run(args, ctx), "#{name}: #{args["op"]} was read"
          assert message =~ "git was not run: this repository's objects lead to ", name
          assert message =~ "which is outside the checkout", name
          refute message =~ "the other workspace's commit", name
        end
      end

      # An alternate inside the checkout is the checkout's own, and is read.
      ws = Path.join(c.base, "inside")
      File.mkdir_p!(ws)
      commit!(ws, %{"mine.txt" => "mine\n"}, "the workspace's own commit")
      inner = Path.join(ws, "vendor")
      File.mkdir_p!(inner)
      commit!(inner, %{"v.txt" => "v\n"}, "vendored")
      vendored = inner |> git!(["rev-parse", "HEAD"]) |> String.trim()
      File.write!(Path.join(ws, ".git/objects/info/alternates"), "../../vendor/.git/objects\n")
      {:ok, workspace} = Workspace.new(ws)

      assert {:ok, shown} =
               GitRead.run(%{"op" => "show", "ref" => vendored}, %{c.ctx | workspace: workspace})

      assert shown =~ "vendored"
    end

    test "a real worktree is read, and its checkout's objects with it", c do
      wt = Path.join(c.base, "wt")
      git!(c.other, ["worktree", "add", "-q", "-b", "wt", wt])
      {:ok, workspace} = Workspace.new(wt)

      assert {:ok, log} = GitRead.run(%{"op" => "log"}, %{c.ctx | workspace: workspace})
      assert log =~ "the other workspace's commit"

      assert {:ok, "## wt" <> _} =
               GitRead.run(%{"op" => "status"}, %{c.ctx | workspace: workspace})

      # A directory inside a checkout reads the checkout, as it always has.
      sub = Path.join(c.root, "lib")
      File.mkdir_p!(sub)
      {:ok, workspace} = Workspace.new(sub)
      assert {:ok, branch} = GitRead.run(%{"op" => "branch"}, %{c.ctx | workspace: workspace})
      assert branch =~ "main"
    end
  end

  describe "the file tools" do
    test "do not write under a .git directory or a .git file", c do
      config = File.read!(Path.join(c.root, ".git/config"))

      for path <- [".git/config", ".git/hooks/pre-commit", ".GIT/config", "lib/.git", ".git"] do
        args = %{"path" => path, "content" => "[core]\n\tfsmonitor = x\n"}
        assert {:error, {:git_dir, ^path}} = WriteFile.run(args, c.ctx)
      end

      edit = %{
        "path" => ".git/config",
        "old_string" => "[core]",
        "new_string" => "[core]\n\tx = y"
      }

      assert {:error, {:git_dir, ".git/config"}} = EditFile.run(edit, c.ctx)

      # Through a link inside the workspace, too.
      File.ln_s!(Path.join(c.root, ".git"), Path.join(c.root, "linked"))

      assert {:error, {:git_dir, "linked/config"}} =
               WriteFile.run(%{"path" => "linked/config", "content" => "x"}, c.ctx)

      assert File.read!(Path.join(c.root, ".git/config")) == config
      refute File.exists?(Path.join(c.root, ".git/hooks/pre-commit"))

      assert Result.describe({:git_dir, ".git/config"}) =~
               ".git/config is inside a .git directory"

      # Nor does onboarding, whose skills may have a directory of their own.
      assert {:error, "`skills/x/.git/config` is in a .git directory" <> _} =
               Onboard.check_path(:repo, "skills/x/.git/config")

      # A name that only starts like one is an ordinary file.
      assert {:ok, _} = WriteFile.run(%{"path" => ".github/x.yml", "content" => "x"}, c.ctx)
      assert {:ok, _} = WriteFile.run(%{"path" => ".gitignore", "content" => "x"}, c.ctx)
    end
  end

  describe "an index of its own" do
    test "stages into a file of the git directory, and leaves the repository's index as it was",
         c do
      File.write!(Path.join(c.root, "new.txt"), "new\n")

      assert {:ok, _, 0} = Troupe.Git.run(c.root, ["add", "-A"], index: "troupe-test-index")
      assert File.exists?(Path.join(c.root, ".git/troupe-test-index"))
      assert {:ok, staged, 0} = Troupe.Git.run(c.root, ["diff", "--cached", "--name-only"])
      assert staged == ""

      assert {:ok, other, 0} =
               Troupe.Git.run(c.root, ["diff", "--cached", "--name-only"],
                 index: "troupe-test-index"
               )

      assert other =~ "new.txt"

      # A name, never a path: nothing but a file beside the index git would use.
      for bad <- ["../outside", "/tmp/x", "index", "", ".hidden"] do
        assert {:error, :bad_index} = Troupe.Git.run(c.root, ["add", "-A"], index: bad)
      end
    end
  end

  # What ran, for a failure's message; built whether or not the assertion fails.
  defp marker(c) do
    case File.read(c.marker) do
      {:ok, ran} -> ran
      {:error, _} -> ""
    end
  end

  defp commit!(dir, files, message \\ "first") do
    git!(dir, ["init", "-q", "--initial-branch", "main"])
    git!(dir, ["config", "user.email", "t@example.com"])
    git!(dir, ["config", "user.name", "Troupe Test"])
    git!(dir, ["config", "commit.gpgSign", "false"])
    for {name, content} <- files, do: File.write!(Path.join(dir, name), content)
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-q", "-m", message])
  end

  defp git!(cwd, args) do
    {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    out
  end
end
