defmodule Troupe.Mounts do
  @moduledoc """
  The roots a session may touch, and at what mode.

  Four kinds, resolved once when the session is created and recorded as a durable
  event so that what a session was allowed to see is part of its history rather than a
  property of a pod that has since been replaced:

      session:/        private, read-write, on the pod's volume
      team:<name>/     the session's team volume, read-only or read-write per grant
      org:/            the org volume from the cluster policy, always read-only
      skills:/<name>/  the pinned config bundle's skills, always read-only

  Two rules make this worth having rather than decorative.

  **A path outside the table does not resolve.** Not "is rejected" — does not resolve,
  because there is nothing to resolve it against. Another team's volume is not a
  forbidden path; it is a path with no meaning in this session.

  **Path checks are not the enforcement for `shell`.** They cannot be: a shell command
  can do anything a process can. The table is also the bind list for the sandbox, so a
  read-only team volume is read-only to the kernel and another team's volume is absent
  from the mount namespace entirely. The table is what the tools check *and* what the
  sandbox is built from, which is why the two can never disagree.
  """

  alias Troupe.Workspace

  defmodule Entry do
    @moduledoc "One root a session may touch."

    @enforce_keys [:name, :root, :mode]
    defstruct [:name, :root, :mode, :kind, :root_key]

    @type t :: %__MODULE__{
            name: String.t(),
            root: Path.t(),
            mode: :ro | :rw,
            kind: :session | :team | :org | :bundle,
            root_key: String.t()
          }
  end

  @enforce_keys [:entries]
  defstruct entries: []

  @type t :: %__MODULE__{entries: [Entry.t()]}

  @doc """
  The table a purely local session has: its workspace, and nothing else.

  Stage 0's behaviour written down. A laptop session has no team volume and no org
  volume, so `session:/` is the whole world and a plain relative path means what it
  always meant.
  """
  @spec local(Path.t()) :: t()
  def local(session_root),
    do: new([%{name: "session", kind: :session, root: session_root, mode: :rw}])

  @doc "Build a table from entries, resolving every root to a real path."
  @spec new([map()]) :: t()
  def new(entries) do
    %__MODULE__{entries: Enum.map(entries, &entry/1)}
  end

  defp entry(%Entry{} = entry), do: entry

  defp entry(attrs) do
    root = Path.expand(attrs[:root] || attrs["root"])

    real =
      case Workspace.real_path(root) do
        {:ok, resolved} -> resolved
        {:error, _reason} -> root
      end

    kind = kind(attrs[:kind] || attrs["kind"])

    %Entry{
      name: to_string(attrs[:name] || attrs["name"]),
      kind: kind,
      root: real,
      mode: entry_mode(kind, mode(attrs[:mode] || attrs["mode"])),
      root_key: Workspace.compare_key(real)
    }
  end

  defp kind(value) when value in [:session, :team, :org, :bundle], do: value
  defp kind("session"), do: :session
  defp kind("team"), do: :team
  defp kind("org"), do: :org
  defp kind("bundle"), do: :bundle
  defp kind(_other), do: :team

  defp mode(value) when value in [:ro, :rw], do: value
  defp mode("ro"), do: :ro
  defp mode("rw"), do: :rw
  defp mode(_other), do: :ro

  # A bundle's skills are the one kind whose mode is not the caller's to choose. The
  # sandbox binds the same table, so `ro` here is also `ro` to the kernel, and a skill
  # cannot carry a script that `shell` could run from its own directory.
  defp entry_mode(:bundle, _mode), do: :ro
  defp entry_mode(_kind, mode), do: mode

  @doc "The session's own root, which is where a bare relative path lands."
  @spec session_root(t()) :: Path.t() | nil
  def session_root(%__MODULE__{} = mounts) do
    case Enum.find(mounts.entries, &(&1.kind == :session)) do
      nil -> nil
      entry -> entry.root
    end
  end

  @doc "One entry by name, or `nil`."
  @spec fetch(t(), String.t()) :: Entry.t() | nil
  def fetch(%__MODULE__{} = mounts, name), do: Enum.find(mounts.entries, &(&1.name == name))

  @doc """
  Resolve a tool-supplied path, or say why it has no meaning here.

  `:write` refuses a read-only mount before anything is opened, so the error a model
  sees names the mount rather than an errno from halfway through a copy.
  """
  @spec resolve(t(), String.t(), :read | :write) ::
          {:ok, Path.t(), Entry.t()} | {:error, term()}
  def resolve(mounts, path, mode \\ :read)

  def resolve(%__MODULE__{} = mounts, path, mode) when is_binary(path) do
    with {:ok, entry, rest} <- entry_for(mounts, path),
         {:ok, resolved} <- within(entry, rest),
         :ok <- writable(entry, mode) do
      {:ok, resolved, entry}
    end
  end

  # Four prefixes and nothing else: `session:`, `org:`, `skills:`, and `team:<name>`.
  # Anything that is not one of them is a session-relative path, which is both what
  # every existing tool call means and what keeps a Windows drive letter from being read
  # as a mount name.
  defp entry_for(mounts, path) do
    case String.split(path, ":", parts: 2) do
      ["session", rest] -> of_kind(mounts, :session, String.trim_leading(rest, "/"))
      ["org", rest] -> of_kind(mounts, :org, String.trim_leading(rest, "/"))
      ["skills", rest] -> of_kind(mounts, :bundle, String.trim_leading(rest, "/"))
      ["team", rest] -> team(mounts, rest)
      # No prefix: the session's own root, and the path is passed through untouched so
      # that an absolute one stays absolute and is rejected rather than reinterpreted.
      _ -> of_kind(mounts, :session, path)
    end
  end

  defp of_kind(mounts, kind, rest) do
    case Enum.find(mounts.entries, &(&1.kind == kind)) do
      nil -> {:error, {:no_such_mount, prefix_name(kind)}}
      entry -> {:ok, entry, rest}
    end
  end

  # The bundle's mount is *named* `skills` because that is the word a model reads and
  # writes; its *kind* is `bundle` because that is what it is a piece of.
  defp prefix_name(:bundle), do: "skills"
  defp prefix_name(kind), do: Atom.to_string(kind)

  # `team:<name>/rest`. The name is in the path because a person reading a log should be
  # able to see which team's volume was written to without knowing what the session's
  # team was.
  defp team(mounts, rest) do
    case rest |> String.trim_leading("/") |> String.split("/", parts: 2) do
      [name | tail] ->
        case Enum.find(mounts.entries, &(&1.kind == :team and &1.name == name)) do
          nil -> {:error, {:no_such_mount, "team:" <> name}}
          entry -> {:ok, entry, List.first(tail) || ""}
        end

      _ ->
        {:error, {:no_such_mount, "team"}}
    end
  end

  defp within(entry, rest) do
    candidate =
      cond do
        rest in ["", "/"] -> entry.root
        # Kept absolute rather than reinterpreted as relative to the mount: turning
        # `/etc/passwd` into a file inside the root would be an escape dressed as a
        # convenience. It is expanded and then checked, like everything else.
        Workspace.absolute?(rest) -> Path.expand(rest)
        true -> Path.expand(rest, entry.root)
      end

    case Workspace.real_path(candidate) do
      {:ok, real} ->
        if inside?(entry, real), do: {:ok, real}, else: {:error, {:outside_mount, entry.name}}

      {:error, _reason} ->
        {:error, {:outside_mount, entry.name}}
    end
  end

  defp inside?(%Entry{root_key: root_key}, path) do
    key = Workspace.compare_key(path)
    key == root_key or String.starts_with?(key, root_key <> "/")
  end

  defp writable(%Entry{mode: :rw}, _mode), do: :ok
  defp writable(_entry, :read), do: :ok
  defp writable(%Entry{name: name}, :write), do: {:error, {:read_only_mount, name}}

  @doc """
  Which mount an absolute path belongs to, and at what mode.

  Used where a path has already been resolved — a filesystem event, a workspace scan —
  and the question is whether the session may see it at all.
  """
  @spec owner(t(), Path.t()) :: Entry.t() | nil
  def owner(%__MODULE__{} = mounts, path), do: Enum.find(mounts.entries, &inside?(&1, path))

  @doc "How a path should be shown to the model: `session:/lib/x.ex`, `team:acme/notes`."
  @spec display(t(), Path.t()) :: String.t()
  def display(%__MODULE__{} = mounts, path) do
    case owner(mounts, path) do
      nil -> path
      entry -> prefix(entry) <> Path.relative_to(path, entry.root)
    end
  end

  defp prefix(%Entry{kind: :team, name: name}), do: "team:" <> name <> "/"
  defp prefix(%Entry{kind: kind}), do: prefix_name(kind) <> ":/"

  @doc "The table as a durable event's data. Roots included: a pod is not a secret."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = mounts) do
    %{
      "mounts" =>
        Enum.map(mounts.entries, fn entry ->
          %{
            "name" => entry.name,
            "kind" => Atom.to_string(entry.kind),
            "root" => entry.root,
            "mode" => Atom.to_string(entry.mode)
          }
        end)
    }
  end

  @doc "Read a table back from a durable event, which is how a restored session gets one."
  @spec from_json(map()) :: t()
  def from_json(%{"mounts" => entries}) when is_list(entries), do: new(entries)
  def from_json(_json), do: %__MODULE__{entries: []}
end
