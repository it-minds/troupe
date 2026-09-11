defmodule Troupe.CLI do
  @moduledoc """
  Command-line parsing.

      troupe                       open the TUI in the current directory
      troupe --watch               TUI with watch mode on
      troupe run [AGENT] "task" [--headless] [--worktree] [--auto-approve] [--workspace DIR]
      troupe resume [SESSION_ID]
      troupe config                show the resolved providers and models (keys masked)
      troupe models [--refresh]    list every model, its window and its price
      troupe --version
  """

  @type args :: %{
          mode: :tui | :run | :resume | :version | :help | :config | :models,
          agent: String.t(),
          task: String.t() | nil,
          headless: boolean(),
          worktree: boolean(),
          auto_approve: boolean(),
          watch: boolean(),
          workspace: String.t(),
          session_id: String.t() | nil,
          refresh: boolean()
        }

  @spec parse([String.t()]) :: {:ok, args()} | {:error, String.t()}
  def parse(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          headless: :boolean,
          worktree: :boolean,
          auto_approve: :boolean,
          watch: :boolean,
          workspace: :string,
          version: :boolean,
          help: :boolean,
          refresh: :boolean
        ]
      )

    base = %{
      mode: :tui,
      agent: "code",
      task: nil,
      headless: Keyword.get(opts, :headless, false),
      worktree: Keyword.get(opts, :worktree, false),
      auto_approve: Keyword.get(opts, :auto_approve, false),
      watch: Keyword.get(opts, :watch, false),
      workspace: Path.expand(Keyword.get(opts, :workspace, File.cwd!())),
      session_id: nil,
      refresh: Keyword.get(opts, :refresh, false)
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

  defp parse_rest([], base), do: {:ok, base}
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
