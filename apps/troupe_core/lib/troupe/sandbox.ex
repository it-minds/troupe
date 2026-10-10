defmodule Troupe.Sandbox do
  @moduledoc """
  Running a command with only the session's mounts visible.

  The Forbidden list says path checks may not be the only enforcement for `shell`, and
  they cannot be: a shell command can do anything a process can, and no amount of
  checking the string it was given changes that. So `shell` runs inside a mount
  namespace built from the same table the file tools resolve against. A read-only team
  volume is read-only to the kernel, and another team's volume is not forbidden — it is
  absent.

  `bubblewrap` does the work, launched by `reaper` like every other process Troupe
  starts, so a sandboxed command is exactly as cancellable and exactly as reapable as an
  unsandboxed one.

  What the namespace has:

  * the session's mounts, bound at their modes and nothing else under them;
  * a private `/proc` and a private `/tmp`, so one session cannot see another's
    processes or leave anything in a shared temporary directory;
  * the runtime the command needs — `/usr`, `/bin`, `/lib` and friends — read-only, and
    the few files in `/etc` that name resolution and user lookup read;
  * `--die-with-parent`, so a sandbox cannot outlive the reaper that launched it.

  **On a worker, always** (Decision 832). A pod's sessions share its volume, and a
  namespace holding one session's mounts is what keeps each from the others' files, so
  the worker's own configuration sets `:always`: every command a session starts there
  runs in one, whatever its mounts or bundle — `shell`, the git and ripgrep the tools
  run (`Troupe.Reaper` wraps what it starts), an ACP agent. A worker that cannot start
  the sandbox, because bubblewrap is not there or the kernel will not let it build a
  namespace, refuses the command and says so once in its log; it never runs it outside.

  **Elsewhere, `:auto`.** A laptop session has one mount, no team volumes, and a user who
  already owns every file the agent can reach, so a namespace would buy nothing and cost
  a dependency: a local daemon wraps `shell` only for a session with a mount besides its
  workspace, where bubblewrap is installed, and nothing else.
  """

  alias Troupe.{Mounts, Reaper}

  require Logger

  # Read-only system roots, and the files name resolution and user lookup read, if they
  # exist. A container image will have some of these and not others, which is why each
  # is checked rather than assumed. Without the second set a command in the sandbox
  # resolved no host name and had no user name.
  @system_roots ~w(/usr /bin /sbin /lib /lib64 /etc/alternatives /etc/ssl /etc/ca-certificates
                   /etc/resolv.conf /etc/hosts /etc/nsswitch.conf /etc/passwd /etc/group)

  @doc """
  Whether this install should sandbox a command that sees `mounts`.

  `:always` is a worker's (Decision 832): every command, whatever its mounts, and one
  the worker cannot sandbox is refused by `check/0`, never run without it. `:auto` — the
  default, a local daemon's — means "when bubblewrap is there and there is more than one
  mount", which is exactly the case where the answer matters on a laptop: a session
  with only its own workspace has nothing to be confined away from. `:never` is off.
  """
  @spec enabled?(Mounts.t() | nil) :: boolean()
  def enabled?(mounts \\ nil) do
    case mode() do
      :never -> false
      :always -> true
      _auto -> available?() and shared_mounts?(mounts)
    end
  end

  @doc "Whether every command must run in the sandbox here, as on a worker (Decision 832)."
  @spec required?() :: boolean()
  def required?, do: mode() == :always

  defp mode, do: Application.get_env(:troupe_core, :sandbox, :auto)

  defp shared_mounts?(nil), do: false
  defp shared_mounts?(%Mounts{entries: entries}), do: Enum.any?(entries, &(&1.kind != :session))

  @doc "Whether `bubblewrap` is installed and runnable."
  @spec available?() :: boolean()
  def available? do
    case executable() do
      nil -> false
      # A configured path that is not there is not availability. A pod told to sandbox
      # with a wrong path must fail loudly rather than run the command unconfined.
      path -> File.exists?(path)
    end
  end

  @doc "Where `bwrap` is, or `nil`."
  @spec executable() :: Path.t() | nil
  def executable do
    Application.get_env(:troupe_core, :bwrap) || Troupe.Executable.find("bwrap")
  end

  @doc """
  The argv that runs `argv` inside the sandbox.

  Returns the command unchanged when sandboxing is off, so callers do not branch: there
  is one code path that launches a command and it is always the same one. `:cwd` is
  where it starts (the session's root by default) and `:home` its `$HOME` (`:cwd` by
  default, as `shell` has always had it).
  """
  @spec wrap([String.t()], Mounts.t(), keyword()) :: [String.t()]
  def wrap(argv, mounts, opts \\ [])

  def wrap(argv, nil, _opts), do: argv

  def wrap(argv, %Mounts{} = mounts, opts) do
    if Keyword.get(opts, :enabled?, enabled?(mounts)) do
      [executable() | flags(mounts, opts)] ++ ["--"] ++ argv
    else
      argv
    end
  end

  defp flags(mounts, opts) do
    cwd = Keyword.get(opts, :cwd) || Mounts.session_root(mounts)

    [
      # A sandbox that outlived the reaper that launched it would be a process Troupe
      # cannot kill, which is the one thing the reaper exists to prevent.
      "--die-with-parent",
      "--unshare-pid",
      "--unshare-ipc",
      "--unshare-uts",
      "--new-session",
      "--proc",
      "/proc",
      "--dev",
      "/dev",
      # Private, so nothing a command leaves in /tmp is visible to another session.
      "--tmpfs",
      "/tmp"
    ] ++
      system_binds() ++
      mount_binds(mounts) ++
      home(Keyword.get(opts, :home, cwd)) ++
      ["--chdir", cwd]
  end

  # The runtime, read-only. Without it there is no shell to run.
  defp system_binds do
    @system_roots
    |> Enum.filter(&File.exists?/1)
    |> Enum.flat_map(&["--ro-bind", &1, &1])
  end

  defp mount_binds(%Mounts{entries: entries}) do
    Enum.flat_map(entries, fn entry ->
      flag = if entry.mode == :rw, do: "--bind", else: "--ro-bind"
      [flag, entry.root, entry.root]
    end)
  end

  # Somewhere writable to be `$HOME`, because a great many tools will not start without
  # one. `shell`'s is its working directory; a command Troupe runs for itself is given
  # the private `/tmp`, so a file the repository carries is never its configuration.
  defp home(dir), do: ["--setenv", "HOME", dir, "--setenv", "TMPDIR", "/tmp"]

  @doc """
  The argv that runs `argv` over `mounts`, or why nothing may run: `check/0`, then
  `wrap/3`. What `Troupe.Reaper` asks before it starts a command.
  """
  @spec command([String.t()], Mounts.t(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def command(argv, %Mounts{} = mounts, opts \\ []) do
    with :ok <- check(), do: {:ok, wrap(argv, mounts, opts)}
  end

  @doc """
  Say what is wrong, when sandboxing is required and cannot be done.

  A worker that must sandbox and cannot must not quietly run the command anyway: that is
  the difference between a confined shell and an unconfined one. It cannot in two ways:
  bubblewrap is not there, or it is and the kernel will not let it build a namespace
  (unprivileged user namespaces off, a seccomp or AppArmor profile that forbids them).
  The second is found by starting one empty sandbox the first time a command asks, once
  for each bubblewrap. Either is logged once and answered every time with a clause a
  tool puts in its answer (no capital, no full stop), so the model can tell the person
  rather than try again.
  """
  @spec check() :: :ok | {:error, String.t()}
  def check do
    cond do
      not required?() -> :ok
      not available?() -> refuse({executable(), :missing}, "bubblewrap is not installed here")
      true -> started(executable())
    end
  end

  defp started(bwrap) do
    key = {__MODULE__, :started, bwrap}

    result =
      case :persistent_term.get(key, :unknown) do
        :unknown -> remember(key, start_one())
        known -> known
      end

    case result do
      {:refused, said} -> refuse({bwrap, said}, "bubblewrap could not start one here (#{said})")
      _ok_or_unknown -> :ok
    end
  end

  # A reaper that would not run the check is no answer about bubblewrap: the command
  # that asked will say why it could not run, and the next one asks again.
  defp remember(_key, :unknown), do: :unknown

  defp remember(key, result) do
    :persistent_term.put(key, result)
    result
  end

  # One empty sandbox, built as a command's is, in the temporary directory.
  defp start_one do
    dir = System.tmp_dir!()

    argv =
      wrap(["/bin/sh", "-c", "exit 0"], Mounts.local(dir), enabled?: true, cwd: dir, home: "/tmp")

    case Reaper.run(dir, argv, timeout_ms: 10_000, sandbox: false) do
      {:ok, _output, 0} -> :ok
      {:ok, _output, :timeout} -> {:refused, "it did not finish in ten seconds"}
      {:ok, output, status} -> {:refused, said(output, status)}
      {:error, _reaper} -> :unknown
    end
  end

  defp said(output, status) do
    case output |> String.split("\n", trim: true) |> List.first() do
      nil -> "it exited with status #{status}"
      line -> line |> String.trim() |> String.slice(0, 200)
    end
  end

  # Logged once for each bubblewrap and reason, not at every command: the brief's git
  # alone asks before every model call.
  defp refuse(key, why) do
    if :persistent_term.get({__MODULE__, :refused}, nil) != key do
      :persistent_term.put({__MODULE__, :refused}, key)

      Logger.error(
        "sandbox: this worker runs every command in a sandbox and #{why}, so no command " <>
          "will run: not the shell tool, not git, not an ACP agent; a worker needs " <>
          "bubblewrap and unprivileged user namespaces"
      )
    end

    {:error,
     "this worker runs every command in a sandbox and #{why}, so no command can run on " <>
       "this worker until it can; the worker's log says the same"}
  end
end
