defmodule Troupe.CLI do
  @moduledoc """
  Command-line parsing.

      troupe                       open the TUI in the current directory
      troupe --watch               TUI with watch mode on
      troupe --no-mouse            TUI without mouse reporting, so the terminal's own selection works
      troupe --full-send           start with every budget/token limit lifted for the session
      troupe run [AGENT] "task" [--headless] [--worktree] [--auto-approve] [--full-send] [--workspace DIR]
      troupe resume [SESSION_ID]   no id: reopen the last session here, picker open
      troupe --remote [PLANE_URL]  open HQ: teams, profiles and sessions on a plane
      troupe login PLANE_URL       sign in to a plane with the device flow
      troupe logout [PLANE_URL]    forget a plane's credentials (--all forgets every one)
      troupe whoami [PLANE_URL]    print who the plane says you are, and your teams
      troupe config                show the resolved providers and models (keys masked); with none, set them up
      troupe config --explain [KEY] [--json]  every setting, or KEY's, and which file set it (secrets masked)
      troupe config validate [PATH]   check the config files, or one; exits 1 on any problem
      troupe config migrate [--write] [PATH]  show, or make, the rewrite to the current spellings
      troupe config trust [PATH]   let a workspace's own files set the trusted keys; --list shows them
      troupe config untrust [PATH] take that back
      troupe config pull [PLANE_URL]  save the plane's default provider and models here (never a key)
      troupe models [--refresh]    list every model, its window and its price
      troupe daemon [ARGS]         the local daemon: `run` (default), `status`, `config`, `models`, `version`
      troupe --version
  """

  @type args :: %{
          mode:
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
            | :login
            | :logout
            | :whoami
            | :daemon,
          agent: String.t(),
          task: String.t() | nil,
          headless: boolean(),
          worktree: boolean(),
          auto_approve: boolean() | nil,
          full_send: boolean() | nil,
          watch: boolean() | nil,
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

  @spec parse([String.t()]) :: {:ok, args()} | {:error, String.t()}
  # Before the option parser sees anything: everything after `daemon` is the daemon's
  # own command line, flags included, and `--refresh` there is not ours to consume.
  def parse(["daemon" | rest]) do
    with {:ok, base} <- parse([]), do: {:ok, %{base | mode: :daemon, daemon_args: rest}}
  end

  def parse(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          headless: :boolean,
          worktree: :boolean,
          auto_approve: :boolean,
          full_send: :boolean,
          watch: :boolean,
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
      )

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

  @spec usage() :: String.t()
  def usage, do: @moduledoc |> String.split("\n") |> Enum.drop(2) |> Enum.join("\n")

  @spec version() :: String.t()
  def version, do: "troupe #{Application.spec(:troupe, :vsn)}"
end
