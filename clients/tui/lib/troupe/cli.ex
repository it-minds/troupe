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
      troupe config                show the resolved providers and models (keys masked)
      troupe models [--refresh]    list every model, its window and its price
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
            | :models
            | :login
            | :logout
            | :whoami,
          agent: String.t(),
          task: String.t() | nil,
          headless: boolean(),
          worktree: boolean(),
          auto_approve: boolean(),
          full_send: boolean(),
          watch: boolean(),
          mouse: boolean() | nil,
          workspace: String.t(),
          session_id: String.t() | nil,
          refresh: boolean(),
          remote: boolean(),
          plane_url: String.t() | nil,
          all: boolean()
        }

  @spec parse([String.t()]) :: {:ok, args()} | {:error, String.t()}
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
          all: :boolean
        ]
      )

    base = %{
      mode: :tui,
      agent: "code",
      task: nil,
      headless: Keyword.get(opts, :headless, false),
      worktree: Keyword.get(opts, :worktree, false),
      auto_approve: Keyword.get(opts, :auto_approve, false),
      full_send: Keyword.get(opts, :full_send, false),
      watch: Keyword.get(opts, :watch, false),
      # nil, not false: no flag means "whatever the `mouse` setting says".
      mouse: Keyword.get(opts, :mouse),
      workspace: Path.expand(Keyword.get(opts, :workspace, File.cwd!())),
      session_id: nil,
      refresh: Keyword.get(opts, :refresh, false),
      remote: Keyword.get(opts, :remote, false),
      plane_url: nil,
      all: Keyword.get(opts, :all, false)
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
  defp parse_rest(["config"], base), do: {:ok, %{base | mode: :config}}
  defp parse_rest(["models"], base), do: {:ok, %{base | mode: :models}}
  defp parse_rest(["resume"], base), do: {:ok, %{base | mode: :resume}}
  defp parse_rest(["resume", sid], base), do: {:ok, %{base | mode: :resume, session_id: sid}}
  defp parse_rest(other, _base), do: {:error, "unknown arguments: #{Enum.join(other, " ")}"}

  @spec usage() :: String.t()
  def usage, do: @moduledoc |> String.split("\n") |> Enum.drop(2) |> Enum.join("\n")

  @spec version() :: String.t()
  def version, do: "troupe #{Application.spec(:troupe, :vsn)}"
end
