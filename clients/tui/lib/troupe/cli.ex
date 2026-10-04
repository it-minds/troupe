defmodule Troupe.CLI do
  @moduledoc """
  Command-line parsing, and the help `troupe --help` prints.

  The help is written from two tables, so that it says what the code does (root Decision
  767): `commands/0`, beside the parser, for the command lines `troupe` takes, and the
  harness's `Troupe.Commands` for the commands typed inside a session, the table
  `commands.list` serves both clients. `docs/user/cli-reference.md` is written from the
  same two by `mix troupe.cli.reference`.
  """

  @type mode ::
          :tui
          | :run
          | :resume
          | :version
          | :help
          | :config
          | :config_explain
          | :config_validate
          | :config_migrate
          | :config_trust
          | :config_untrust
          | :config_trust_list
          | :config_pull
          | :models
          | :doctor
          | :login
          | :logout
          | :whoami
          | :daemon

  @type args :: %{
          mode: mode(),
          agent: String.t(),
          task: String.t() | nil,
          headless: boolean(),
          worktree: boolean(),
          auto_approve: boolean() | nil,
          full_send: boolean() | nil,
          watch: boolean() | nil,
          private: boolean(),
          mouse: boolean() | nil,
          workspace: String.t(),
          session_id: String.t() | nil,
          refresh: boolean(),
          remote: boolean(),
          plane_url: String.t() | nil,
          all: boolean(),
          daemon_args: [String.t()],
          explain: boolean(),
          json: boolean(),
          write: boolean(),
          list: boolean(),
          key: String.t() | nil,
          path: String.t() | nil
        }

  @switches [
    headless: :boolean,
    worktree: :boolean,
    auto_approve: :boolean,
    full_send: :boolean,
    watch: :boolean,
    private: :boolean,
    mouse: :boolean,
    workspace: :string,
    version: :boolean,
    help: :boolean,
    refresh: :boolean,
    remote: :boolean,
    all: :boolean,
    explain: :boolean,
    json: :boolean,
    write: :boolean,
    list: :boolean
  ]

  # Every command line `troupe` takes: how it is typed, what it does, and command lines
  # that are it. The suite parses each of those, and holds the modes they reach equal to
  # `mode()` and every switch in `@switches` to one these lines name, so the help can
  # neither list what the parser refuses nor leave out what it takes.
  @commands [
    {"troupe", "open the TUI in the current directory", [[]]},
    {"troupe --workspace DIR", "open the TUI rooted at DIR, wherever it is started",
     [["--workspace", "."]]},
    {"troupe --watch", "TUI with watch mode on", [["--watch"]]},
    {"troupe --no-mouse", "TUI without mouse reporting, so the terminal's own selection works",
     [["--no-mouse"]]},
    {"troupe --full-send", "start with every budget/token limit lifted for the session",
     [["--full-send"]]},
    {"troupe --private", "a private session, sealed to the plane you are signed in to",
     [["--private"]]},
    {~s(troupe run [AGENT] "task" [--headless] [--worktree] [--auto-approve] [--full-send] [--private] [--workspace DIR]),
     "one task: in the TUI, or with --headless printed line by line until the agent rests",
     [["run", "task"], ["run", "plan", "task", "--headless", "--workspace", "."]]},
    {"troupe resume [SESSION_ID]", "no id: reopen the last session here, picker open",
     [["resume"], ["resume", "id"]]},
    {"troupe --remote [PLANE_URL]", "open HQ: teams, profiles and sessions on a plane",
     [["--remote"]]},
    {"troupe login PLANE_URL", "sign in to a plane with the device flow",
     [["login", "https://plane.example"]]},
    {"troupe logout [PLANE_URL]",
     "forget a plane's credentials and sign this machine's daemon out of it (--all: every plane)",
     [["logout"], ["logout", "--all"]]},
    {"troupe whoami [PLANE_URL]", "print who the plane says you are, and your teams", [["whoami"]]},
    {"troupe config",
     "show the resolved providers and models (keys masked); with none, set them up", [["config"]]},
    {"troupe config --explain [KEY] [--json]",
     "every setting, or KEY's, and which file set it (secrets masked)",
     [["config", "--explain"], ["config", "--explain", "max_turns", "--json"]]},
    {"troupe config validate [PATH]", "check the config files, or one; exits 1 on any problem",
     [["config", "validate"]]},
    {"troupe config migrate [--write] [PATH]",
     "show, or make, the rewrite to the current spellings", [["config", "migrate", "--write"]]},
    {"troupe config trust [PATH]",
     "let a workspace's own files set the trusted keys; --list shows them",
     [["config", "trust"], ["config", "trust", "--list"]]},
    {"troupe config untrust [PATH]", "take a workspace's trust back", [["config", "untrust"]]},
    {"troupe config pull [PLANE_URL]",
     "save the plane's default provider and models here (never a key)", [["config", "pull"]]},
    {"troupe models [--refresh]", "list every model, its window and its price",
     [["models", "--refresh"]]},
    {"troupe doctor", "check the setup: provider, key, daemon, PATH, plane; exits 1 on a failure",
     [["doctor"]]},
    {"troupe daemon [ARGS]",
     "the local daemon: `run` (default), `status`, `config`, `models`, `login on|off`, `version`",
     [["daemon"], ["daemon", "status"]]},
    {"troupe --version", "print the version", [["--version"]]},
    {"troupe --help", "print the command lines and the commands inside a session", [["--help"]]}
  ]

  @spec parse([String.t()]) :: {:ok, args()} | {:error, String.t()}
  # Before the option parser sees anything: everything after `daemon` is the daemon's
  # own command line, flags included, and `--refresh` there is not ours to consume.
  def parse(["daemon" | rest]) do
    with {:ok, base} <- parse([]), do: {:ok, %{base | mode: :daemon, daemon_args: rest}}
  end

  def parse(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    base = %{
      mode: :tui,
      agent: "build",
      task: nil,
      headless: Keyword.get(opts, :headless, false),
      worktree: Keyword.get(opts, :worktree, false),
      # nil, not false: no flag means "whatever the config says" (`session_config/1`).
      auto_approve: Keyword.get(opts, :auto_approve),
      full_send: Keyword.get(opts, :full_send),
      watch: Keyword.get(opts, :watch),
      # Not a setting: `session.create` takes it beside the config, and no file says it.
      private: Keyword.get(opts, :private, false),
      # nil, not false: no flag means "whatever the `mouse` setting says".
      mouse: Keyword.get(opts, :mouse),
      workspace: Path.expand(Keyword.get(opts, :workspace, File.cwd!())),
      session_id: nil,
      refresh: Keyword.get(opts, :refresh, false),
      remote: Keyword.get(opts, :remote, false),
      plane_url: nil,
      all: Keyword.get(opts, :all, false),
      daemon_args: [],
      explain: Keyword.get(opts, :explain, false),
      json: Keyword.get(opts, :json, false),
      write: Keyword.get(opts, :write, false),
      list: Keyword.get(opts, :list, false),
      key: nil,
      path: nil
    }

    cond do
      invalid != [] ->
        {:error, "unknown option: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}"}

      opts[:version] ->
        {:ok, %{base | mode: :version}}

      opts[:help] ->
        {:ok, %{base | mode: :help}}

      true ->
        parse_rest(rest, base)
    end
  end

  # `--remote` on its own opens HQ; `--remote <url>` (or `troupe --remote url`)
  # picks a plane other than the one last logged in to.
  defp parse_rest([], %{remote: true} = base), do: {:ok, base}
  defp parse_rest([], base), do: {:ok, base}
  defp parse_rest([url], %{remote: true} = base), do: {:ok, %{base | plane_url: url}}

  defp parse_rest(["login", url], base), do: {:ok, %{base | mode: :login, plane_url: url}}
  defp parse_rest(["login"], _base), do: {:error, "usage: troupe login PLANE_URL"}
  defp parse_rest(["logout"], base), do: {:ok, %{base | mode: :logout}}
  defp parse_rest(["logout", url], base), do: {:ok, %{base | mode: :logout, plane_url: url}}
  defp parse_rest(["whoami"], base), do: {:ok, %{base | mode: :whoami}}
  defp parse_rest(["whoami", url], base), do: {:ok, %{base | mode: :whoami, plane_url: url}}

  defp parse_rest(["run", task], base), do: {:ok, %{base | mode: :run, task: task}}

  defp parse_rest(["run", agent, task], base),
    do: {:ok, %{base | mode: :run, agent: agent, task: task}}

  defp parse_rest(["run"], _base), do: {:error, "usage: troupe run [AGENT] \"task\""}
  # `--explain` names at most one key; `--json` alone is the whole explanation as JSON.
  defp parse_rest(["config"], %{explain: explain, json: json} = base) when explain or json,
    do: {:ok, %{base | mode: :config_explain}}

  defp parse_rest(["config", key], %{explain: true} = base),
    do: {:ok, %{base | mode: :config_explain, key: key}}

  defp parse_rest(["config", "validate"], base), do: {:ok, %{base | mode: :config_validate}}

  defp parse_rest(["config", "validate", path], base),
    do: {:ok, %{base | mode: :config_validate, path: path}}

  defp parse_rest(["config", "migrate"], base), do: {:ok, %{base | mode: :config_migrate}}

  defp parse_rest(["config", "migrate", path], base),
    do: {:ok, %{base | mode: :config_migrate, path: path}}

  defp parse_rest(["config", "trust"], %{list: true} = base),
    do: {:ok, %{base | mode: :config_trust_list}}

  # No PATH is the workspace: the current directory, or `--workspace`.
  defp parse_rest(["config", "trust" | path], %{list: false} = base) when length(path) <= 1,
    do: {:ok, %{base | mode: :config_trust, path: List.first(path)}}

  defp parse_rest(["config", "untrust" | path], %{list: false} = base) when length(path) <= 1,
    do: {:ok, %{base | mode: :config_untrust, path: List.first(path)}}

  defp parse_rest(["config"], base), do: {:ok, %{base | mode: :config}}
  defp parse_rest(["config", "pull"], base), do: {:ok, %{base | mode: :config_pull}}

  defp parse_rest(["config", "pull", url], base),
    do: {:ok, %{base | mode: :config_pull, plane_url: url}}

  defp parse_rest(["models"], base), do: {:ok, %{base | mode: :models}}
  defp parse_rest(["doctor"], base), do: {:ok, %{base | mode: :doctor}}
  defp parse_rest(["resume"], base), do: {:ok, %{base | mode: :resume}}
  defp parse_rest(["resume", sid], base), do: {:ok, %{base | mode: :resume, session_id: sid}}
  defp parse_rest(other, _base), do: {:error, "unknown arguments: #{Enum.join(other, " ")}"}

  @doc """
  What the command line asks of a new session's config: only the switches it was given.

  `--auto-approve`, `--watch` and `--full-send` (and their `--no-` forms) beat the config
  files for one session; a switch not given leaves the files' value in force, so
  `auto_approve: true` in a config file applies to `troupe` as it does to every other
  client. These three are all a client may set; the daemon refuses the rest, since the
  provider and its key are the machine's.
  """
  @spec session_config(args()) :: map()
  def session_config(args) do
    args
    |> Map.take([:auto_approve, :watch, :full_send])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc "Every command line `troupe` takes, as `{usage, what it does, command lines that are it}`."
  @spec commands() :: [{String.t(), String.t(), [[String.t()]]}]
  def commands, do: @commands

  @doc false
  @spec switches() :: keyword(atom())
  def switches, do: @switches

  @doc "The command lines, one to a line: the answer to one that does not parse, too."
  @spec usage() :: String.t()
  def usage, do: columns(for {usage, what, _argv} <- @commands, do: {usage, what})

  @doc """
  What `troupe --help` prints: the command lines, then the built-in commands typed inside
  a session, by section, from the harness's table. Read from the table compiled into this
  binary, so it needs no daemon.
  """
  @spec help() :: String.t()
  def help do
    sections =
      Troupe.Commands.builtins()
      |> Enum.chunk_by(& &1["section"])
      |> Enum.map_join("\n", fn [%{"section" => section} | _] = entries ->
        String.capitalize(section) <> "\n" <> columns(Enum.map(entries, &slash_row/1))
      end)

    """
    #{usage()}

    Inside a session every command starts with /, and / on an empty line, Ctrl-K or /help
    opens them as a palette, filtered as you type.

    #{sections}

    Each agent is a command too, /build <prompt> or /plan <prompt> (/agents lists them),
    and so is each <name>.md in your config's commands/ or the workspace's .troupe/commands/.\
    """
  end

  defp slash_row(%{"usage" => usage, "summary" => summary, "aliases" => []}), do: {usage, summary}

  defp slash_row(%{"usage" => usage, "summary" => summary, "aliases" => aliases}),
    do: {usage, "#{summary} (also #{Enum.map_join(aliases, ", ", &("/" <> &1))})"}

  # Two columns, the second at a fixed tab; a first column too wide for it puts the
  # second on the line below, at the tab.
  @tab 34

  defp columns(rows) do
    Enum.map_join(rows, "\n", fn {left, right} ->
      left = "  " <> left

      if String.length(left) + 2 <= @tab,
        do: String.pad_trailing(left, @tab) <> right,
        else: left <> "\n" <> String.duplicate(" ", @tab) <> right
    end)
  end

  @spec version() :: String.t()
  def version, do: "troupe #{Application.spec(:troupe, :vsn)}"
end
