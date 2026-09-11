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
  * the runtime the command needs — `/usr`, `/bin`, `/lib` and friends — read-only;
  * `--die-with-parent`, so a sandbox cannot outlive the reaper that launched it.

  Off by default outside a pod. A laptop session has one mount, no team volumes, and a
  user who already owns every file the agent can reach, so a namespace would buy nothing
  and cost a dependency.
  """

  alias Troupe.Mounts

  # Read-only system roots, if they exist. A container image will have some of these and
  # not others, which is why each is checked rather than assumed.
  @system_roots ~w(/usr /bin /sbin /lib /lib64 /etc/alternatives /etc/ssl /etc/ca-certificates)

  @doc """
  Whether this install should sandbox.

  `:auto` — the default — means "when bubblewrap is there and there is more than one
  mount", which is exactly the case where the answer matters: a session with only its
  own workspace has nothing to be confined away from.
  """
  @spec enabled?(Mounts.t() | nil) :: boolean()
  def enabled?(mounts \\ nil) do
    case Application.get_env(:troupe_core, :sandbox, :auto) do
      :never -> false
      :always -> true
      _auto -> available?() and shared_mounts?(mounts)
    end
  end

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
    Application.get_env(:troupe_core, :bwrap) || System.find_executable("bwrap")
  end

  @doc """
  The argv that runs `argv` inside the sandbox.

  Returns the command unchanged when sandboxing is off, so callers do not branch: there
  is one code path that launches a command and it is always the same one.
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
      home(cwd) ++
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
  # one — and it is inside the namespace, so it goes away with the command.
  defp home(cwd), do: ["--setenv", "HOME", cwd, "--setenv", "TMPDIR", "/tmp"]

  @doc """
  Say what is wrong, when sandboxing is required and cannot be done.

  A pod that was told to sandbox and cannot must not quietly run the command anyway:
  that is the difference between a confined shell and an unconfined one.
  """
  @spec check() :: :ok | {:error, String.t()}
  def check do
    cond do
      Application.get_env(:troupe_core, :sandbox, :auto) != :always -> :ok
      available?() -> :ok
      true -> {:error, "sandboxing is required here and bubblewrap is not installed"}
    end
  end
end
