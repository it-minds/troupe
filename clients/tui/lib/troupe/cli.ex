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
          | :setup
          | :config_explain
          | :config_validate
          | :config_migrate
          | :config_trust
          | :config_untrust
          | :config_trust_list
          | :config_pull
          | :memory
          | :models
          | :doctor
          | :instructions_check
          | :onboard
          | :bench
          | :login
          | :logout
          | :whoami
          | :plane_key
          | :plane_key_accept
          | :daemon
          | :update

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
          prompt: String.t() | nil,
          session_id: String.t() | nil,
          latest: boolean(),
          refresh: boolean(),
          remote: boolean(),
          plane_url: String.t() | nil,
          all: boolean(),
          daemon_args: [String.t()],
          explain: boolean(),
          explain_session: String.t() | nil,
          json: boolean(),
          bench: boolean(),
          write: boolean(),
          list: boolean(),
          live: boolean(),
          repeat: pos_integer() | nil,
          model: String.t() | nil,
          yes: boolean(),
          md: String.t() | nil,
          compare: boolean(),
          json_path: String.t() | nil,
          ref: String.t() | nil,
          suite: String.t() | nil,
          scenario: String.t() | nil,
          keep: String.t() | nil,
          key: String.t() | nil,
          path: String.t() | nil,
          check: boolean(),
          rollback: boolean(),
          update_version: String.t() | nil,
          edit: boolean(),
          clear: boolean()
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
    prompt: :string,
    version: :boolean,
    help: :boolean,
    resume: :boolean,
    refresh: :boolean,
    remote: :boolean,
    all: :boolean,
    explain: :boolean,
    session: :string,
    json: :boolean,
    bench: :boolean,
    write: :boolean,
    list: :boolean,
    live: :boolean,
    repeat: :integer,
    model: :string,
    yes: :boolean,
    md: :string,
    compare: :boolean,
    suite: :string,
    scenario: :string,
    keep: :string,
    edit: :boolean,
    clear: :boolean
  ]

  # Every command line `troupe` takes: how it is typed, what it does, and command lines
  # that are it. The suite parses each of those, and holds the modes they reach equal to
  # `mode()` and every switch in `@switches` to one these lines name, so the help can
  # neither list what the parser refuses nor leave out what it takes.
  @commands [
    {"troupe", "open the TUI in the current directory", [[]]},
    {"troupe --workspace DIR", "open the TUI rooted at DIR, wherever it is started",
     [["--workspace", "."]]},
    {~s(troupe --prompt "TEXT" [--workspace DIR]),
     "open the TUI with TEXT in its input, the cursor after it, not yet sent",
     [["--prompt", "@lib/app.ex "], ["--prompt", "x", "--workspace", "."]]},
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
    {"troupe resume [SESSION_ID | latest] [--private]",
     "no id: the newest session here, picker open; latest, or --private for the newest private one: " <>
       "straight in (troupe --resume is the same)",
     [
       ["resume"],
       ["resume", "id"],
       ["resume", "latest"],
       ["resume", "--private"],
       ["--resume", "id"]
     ]},
    {~s(troupe resume SESSION_ID|latest|--private --headless "message"),
     "one turn on that session, printed as run --headless prints it, then exit",
     [["resume", "id", "--headless", "hi"], ["resume", "--private", "--headless", "hi"]]},
    {"troupe --remote [PLANE_URL]", "open HQ: teams, profiles and sessions on a plane",
     [["--remote"]]},
    {"troupe login PLANE_URL", "sign in to a plane with the device flow",
     [["login", "https://plane.example"]]},
    {"troupe logout [PLANE_URL]",
     "forget a plane's credentials and sign this machine's daemon out of it (--all: every plane); " <>
       "without a plane named, out of your own MCP servers too, revoked at their providers",
     [["logout"], ["logout", "--all"]]},
    {"troupe whoami [PLANE_URL]", "print who the plane says you are, and your teams", [["whoami"]]},
    {"troupe plane-key [PLANE_URL]",
     "the key the plane signs what it tells clients with, as this machine pinned it at sign-in, " <>
       "and a new one it offers instead", [["plane-key"], ["plane-key", "https://plane.example"]]},
    {"troupe plane-key accept FINGERPRINT [PLANE_URL]",
     "trust the plane's new signing key, by the fingerprint you checked with its administrators",
     [
       ["plane-key", "accept", "SHA256:abc"],
       ["plane-key", "accept", "SHA256:abc", "https://plane.example"]
     ]},
    {"troupe setup",
     "set up the provider, its key, the models, a first project and the daemon at login, " <>
       "one screen at a time; Esc leaves with nothing written",
     [["setup"], ["setup", "--workspace", "."]]},
    {"troupe config",
     "show the resolved providers and models (keys masked); with none, set them up", [["config"]]},
    {"troupe config --explain [KEY] [--json]",
     "every setting, or KEY's, and which file set it (secrets masked)",
     [["config", "--explain"], ["config", "--explain", "max_turns", "--json"]]},
    {"troupe config --explain [KEY] [--json] --session SESSION_ID",
     "what is in force in a running session, here or on a worker pod of the plane you are " <>
       "signed in to, and where each part came from: its profile, the platform, its terms, its files",
     [
       ["config", "--explain", "--session", "id"],
       ["config", "--explain", "max_turns", "--json", "--session", "id"]
     ]},
    {"troupe config validate [PATH]", "check the config files, or one; exits 1 on any problem",
     [["config", "validate"]]},
    {"troupe config migrate [--write] [PATH]",
     "show, or make, the rewrite to the current spellings", [["config", "migrate", "--write"]]},
    {"troupe config trust [PATH]",
     "let a workspace's own files set the trusted keys; --list shows them",
     [["config", "trust"], ["config", "trust", "--list"]]},
    {"troupe config untrust [PATH]", "take a workspace's trust back", [["config", "untrust"]]},
    {"troupe config pull [PLANE_URL]",
     "fetch the organisation's defaults and limits from the plane now (never a key)",
     [["config", "pull"]]},
    {"troupe memory [--edit | --clear]",
     "your own memory on the plane, which every session of yours reads on every machine: " <>
       "show it, edit it in $EDITOR, or clear it; an agent of yours only ever adds to it",
     [["memory"], ["memory", "--edit"], ["memory", "--clear"]]},
    {"troupe models [--refresh]",
     "what each provider serves, its window and its price; asked again when stale, or now with --refresh",
     [["models", "--refresh"]]},
    {"troupe models --json [--workspace DIR] [--refresh]",
     "the same as one JSON object for a program: models, roles, catalog, providers; never a key",
     [["models", "--json"], ["models", "--json", "--workspace", ".", "--refresh"]]},
    {"troupe doctor [--json]",
     "check the setup: provider, key, models, daemon, PATH, plane; exits 1 on a failure",
     [["doctor"], ["doctor", "--json"]]},
    {"troupe doctor --bench [--json]",
     "the same, then a turn of tool calls, a cut output, a compaction, a cancel, a replay, " <>
       "four onboarded repositories and a memory whose command's file changed against a " <>
       "scripted model: offline, in seconds",
     [["doctor", "--bench"], ["doctor", "--bench", "--json"]]},
    {"troupe instructions check [--workspace DIR] [--json]",
     "check the instruction files a session here reads: contradictions, missing paths and programs, repeats; " <>
       "and onboarded files whose source has changed, or a workspace onboarded under older " <>
       "rules; exits 1 on one",
     [["instructions", "check"], ["instructions", "check", "--workspace", ".", "--json"]]},
    {"troupe onboard [--workspace DIR] [--yes] [--json] [--all]",
     "bring other tools' instruction files, rules, agents and commands into AGENTS.md, " <>
       ".troupe/ and your config, each shown as a diff and written only if you say yes; a new " <>
       "AGENTS.md is its own question, never answered by --yes; --all asks again about what " <>
       "you left out",
     [["onboard"], ["onboard", "--workspace", ".", "--yes"], ["onboard", "--json", "--all"]]},
    {"troupe bench [--json [FILE]] [--md FILE]",
     "measure what a turn costs and does, offline, against the budgets CI holds; exits 1 past one",
     [["bench"], ["bench", "--json"], ["bench", "--json", "bench.json", "--md", "bench.md"]]},
    {"troupe bench --live [--suite smoke|standard] [--scenario NAME,...] [--repeat N] [--model M] [--yes] [--keep DIR] [--json [FILE]] [--md FILE]",
     "tasks against your own provider, under a cap it prints and asks about first; scored, and kept in a history",
     [
       ["bench", "--live"],
       ["bench", "--live", "--repeat", "3", "--model", "m", "--yes", "--json", "live.json"],
       ["bench", "--live", "--suite", "standard", "--keep", "runs"],
       ["bench", "--live", "--scenario", "fix_test,large_log"]
     ]},
    {"troupe bench --compare [VERSION|MODEL]",
     "the last live bench against the one before it, or against a version's or a model's",
     [["bench", "--compare"], ["bench", "--compare", "0.8.1-beta"]]},
    {"troupe daemon [ARGS]",
     "the local daemon: `run` (default), `status`, `open` (the web app, connected to it), " <>
       "`config`, `models`, `login on|off`, `version`",
     [["daemon"], ["daemon", "status"], ["daemon", "open"]]},
    {"troupe update [--check] [--version X]",
     "install the latest release, or X, over this troupe and troupe-daemon: its signature checked " <>
       "against the release key this build carries, each file against the signed manifest, the daemon " <>
       "replaced between turns; --check says what is installed, the latest release and what an update would do",
     [["update"], ["update", "--check"], ["update", "--version", "0.13.0"]]},
    {"troupe update --rollback",
     "put the troupe and troupe-daemon from before the last update back",
     [["update", "--rollback"]]},
    {"troupe --version", "print the version", [["--version"]]},
    {"troupe --help", "print the command lines and the commands inside a session", [["--help"]]}
  ]

  @spec parse([String.t()]) :: {:ok, args()} | {:error, String.t()}
  # Before the option parser sees anything: everything after `daemon` is the daemon's
  # own command line, flags included, and `--refresh` there is not ours to consume.
  def parse(["daemon" | rest]) do
    with {:ok, base} <- parse([]), do: {:ok, %{base | mode: :daemon, daemon_args: rest}}
  end

  # `--json` and `--compare` take a value or none (TUI Decision 141): the word after one,
  # unless it is a flag, is its value, taken out before the option parser sees a switch
  # with no value and a word it does not place.
  def parse(["bench" | _] = argv) do
    {argv, values} = optional_values(argv, ["--json", "--compare"], [], %{})

    with {:ok, args} <- parse_argv(argv) do
      {:ok, %{args | json_path: values["--json"], ref: values["--compare"]}}
    end
  end

  # `--version` names the release to install here; anywhere else it is the program's own
  # (Decision 865). A tag's `v` is taken off: the release's number is without it.
  def parse(["update" | rest]) do
    case OptionParser.parse(rest, strict: [check: :boolean, rollback: :boolean, version: :string]) do
      {opts, [], []} ->
        rollback = Keyword.get(opts, :rollback, false)
        version = if v = opts[:version], do: String.replace_prefix(v, "v", "")

        if rollback and (version != nil or opts[:check]) do
          {:error,
           "troupe update --rollback takes nothing else: it puts back what the last update replaced"}
        else
          with {:ok, base} <- parse_argv([]) do
            {:ok,
             %{
               base
               | mode: :update,
                 check: Keyword.get(opts, :check, false),
                 rollback: rollback,
                 update_version: version
             }}
          end
        end

      {_opts, words, []} ->
        {:error, "unknown arguments: update #{Enum.join(words, " ")}"}

      {_opts, _words, invalid} ->
        {:error,
         "unknown option: #{Enum.map_join(invalid, ", ", &elem(&1, 0))} (troupe update takes --check, --version X and --rollback)"}
    end
  end

  def parse(argv), do: parse_argv(argv)

  defp optional_values([flag, value | rest], flags, acc, values) when is_binary(value) do
    if flag in flags and not String.starts_with?(value, "-"),
      do: optional_values(rest, flags, [flag | acc], Map.put(values, flag, value)),
      else: optional_values([value | rest], flags, [flag | acc], values)
  end

  defp optional_values([arg | rest], flags, acc, values),
    do: optional_values(rest, flags, [arg | acc], values)

  defp optional_values([], _flags, acc, values), do: {Enum.reverse(acc), values}

  defp parse_argv(argv) do
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
      # What the TUI's input opens with (Decision 150); the TUI mode alone reads it.
      prompt: Keyword.get(opts, :prompt),
      session_id: nil,
      latest: false,
      refresh: Keyword.get(opts, :refresh, false),
      remote: Keyword.get(opts, :remote, false),
      plane_url: nil,
      all: Keyword.get(opts, :all, false),
      daemon_args: [],
      explain: Keyword.get(opts, :explain, false),
      # `config --explain --session ID`: that running session's configuration, not the files'.
      explain_session: Keyword.get(opts, :session),
      json: Keyword.get(opts, :json, false),
      bench: Keyword.get(opts, :bench, false),
      write: Keyword.get(opts, :write, false),
      list: Keyword.get(opts, :list, false),
      live: Keyword.get(opts, :live, false),
      repeat: Keyword.get(opts, :repeat),
      model: Keyword.get(opts, :model),
      yes: Keyword.get(opts, :yes, false),
      md: Keyword.get(opts, :md),
      compare: Keyword.get(opts, :compare, false),
      json_path: nil,
      ref: nil,
      suite: Keyword.get(opts, :suite),
      scenario: Keyword.get(opts, :scenario),
      keep: Keyword.get(opts, :keep),
      key: nil,
      path: nil,
      check: false,
      rollback: false,
      update_version: nil,
      edit: Keyword.get(opts, :edit, false),
      clear: Keyword.get(opts, :clear, false)
    }

    cond do
      invalid != [] ->
        {:error, "unknown option: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}"}

      opts[:version] ->
        {:ok, %{base | mode: :version}}

      opts[:help] ->
        {:ok, %{base | mode: :help}}

      # `troupe --resume …` is `troupe resume …`, the spelling issue #484 asked for.
      opts[:resume] ->
        parse_rest(["resume" | rest], base)

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
  defp parse_rest(["plane-key"], base), do: {:ok, %{base | mode: :plane_key}}

  defp parse_rest(["plane-key", "accept", fingerprint], base),
    do: {:ok, %{base | mode: :plane_key_accept, key: fingerprint}}

  defp parse_rest(["plane-key", "accept", fingerprint, url], base),
    do: {:ok, %{base | mode: :plane_key_accept, key: fingerprint, plane_url: url}}

  defp parse_rest(["plane-key", "accept"], _base),
    do: {:error, "usage: troupe plane-key accept FINGERPRINT [PLANE_URL]"}

  defp parse_rest(["plane-key", url], base), do: {:ok, %{base | mode: :plane_key, plane_url: url}}

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
  defp parse_rest(["setup"], base), do: {:ok, %{base | mode: :setup}}
  defp parse_rest(["config", "pull"], base), do: {:ok, %{base | mode: :config_pull}}

  defp parse_rest(["config", "pull", url], base),
    do: {:ok, %{base | mode: :config_pull, plane_url: url}}

  defp parse_rest(["memory"], %{edit: true, clear: true}),
    do: {:error, "troupe memory takes --edit or --clear, not both"}

  defp parse_rest(["memory"], base), do: {:ok, %{base | mode: :memory}}
  defp parse_rest(["models"], base), do: {:ok, %{base | mode: :models}}
  defp parse_rest(["doctor"], base), do: {:ok, %{base | mode: :doctor}}

  defp parse_rest(["instructions", "check"], base),
    do: {:ok, %{base | mode: :instructions_check}}

  defp parse_rest(["onboard"], base), do: {:ok, %{base | mode: :onboard}}

  defp parse_rest(["bench"], base), do: {:ok, %{base | mode: :bench}}

  # `troupe resume` (Decision 812): no word is the picker on the newest session here;
  # `latest`, or `--private` for the newest private one, goes straight in; an id is that
  # session. With `--headless` the last word is the message one turn runs with, and the
  # session is named, there being no picker to choose one on: an id, `latest`, or
  # `--private` alone.
  defp parse_rest(["resume" | words], %{headless: true} = base) do
    case {words, base.private} do
      {[target, message], _private} -> resume([target], %{base | task: message})
      {[message], true} -> resume([], %{base | task: message})
      _ -> {:error, ~s(usage: troupe resume SESSION_ID|latest|--private --headless "message")}
    end
  end

  defp parse_rest(["resume" | target], base) when length(target) <= 1, do: resume(target, base)
  defp parse_rest(other, _base), do: {:error, "unknown arguments: #{Enum.join(other, " ")}"}

  defp resume([], base), do: {:ok, %{base | mode: :resume, latest: base.private}}
  defp resume(["latest"], base), do: {:ok, %{base | mode: :resume, latest: true}}
  defp resume([sid], base), do: {:ok, %{base | mode: :resume, session_id: sid}}

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

    Each agent is a command too, /build <prompt> or /plan <prompt> (/agents manages them),
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
