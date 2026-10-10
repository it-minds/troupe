defmodule Troupe.Watch.Branch do
  @moduledoc """
  Where a watch trigger goes (Decision 844).

  A saved `AI!` or `AI?` comment is not a considered request, so it goes to a cheap,
  few-turn agent (TUI Decision 67): `quick` for a change, `answer` for a question. It runs
  as a branch of the session that watches — a session of its own whose `parent` is that
  one — in the same checkout, because the comment and the change it asks for are in files
  there that need not be committed. The session's own agent is told nothing. A person who
  wants another agent there redefines `quick` or `answer` in `.troupe/agents/` or their
  own `agents/`, which is also what `/quick` starts: an `AI!` and `/quick` are one path.

  Anything that writes a file can write a comment — a pull, a generator, another tool — so
  what a trigger starts asks before every write, edit, shell command and MCP server's
  tool, whatever `auto_approve`, an agent's own `auto` and a server's `permission: auto`
  say, until the person turns `watch_auto_approve` on. And it does not watch: it works in the files the watcher sees.
  """

  alias Troupe.Agent.Definitions
  alias Troupe.Watch.Trigger

  @doc "The agent a trigger starts: `answer` when every marker is a question, else `quick`."
  @spec agent(Trigger.t()) :: String.t()
  def agent(%Trigger{mode: :question}), do: "answer"
  def agent(%Trigger{}), do: "quick"

  @doc """
  Start the branch for a trigger. The watcher then follows it and gives it the trigger as
  a `watch` input, which runs an `AI?` under the plan permission set.

  `opts`: `:parent` (the watching session), `:workspace` (its checkout), `:auto_approve`
  (`watch_auto_approve`), and the `:config_overrides` and `:fake` the parent was started
  with, so the branch reads the configuration it does.
  """
  @spec start(Trigger.t(), keyword()) :: {:ok, %{id: String.t(), pid: pid()}} | {:error, term()}
  def start(%Trigger{} = trigger, opts) do
    auto? = Keyword.get(opts, :auto_approve, false) == true
    workspace = Keyword.fetch!(opts, :workspace)

    overrides =
      Keyword.get(opts, :config_overrides, []) ++ [watch: false, auto_approve: auto?]

    # `hold_auto`: every agent's own `auto` and every MCP server's `permission: auto` held
    # back in the branch (`Troupe.Session.build_opts/1`, `Troupe.Session.MCP`), as Decisions
    # 825 and 830 hold a workspace's until it is trusted: each tool asks by its own
    # default, which for a write, an edit, a shell command or a server's tool is to ask.
    start = [
      workspace: workspace,
      agent: agent(trigger),
      parent: Keyword.fetch!(opts, :parent),
      fake: Keyword.get(opts, :fake),
      config_overrides: overrides,
      hold_auto: not auto?
    ]

    with {:ok, session} <- Troupe.start_session(start), do: {:ok, Map.take(session, [:id, :pid])}
  end

  @doc "Every definition's `auto` entries taken out, so each of those tools asks again."
  @spec hold_auto(Definitions.t()) :: Definitions.t()
  def hold_auto(%Definitions{by_name: by_name} = definitions) do
    held =
      Map.new(by_name, fn {name, definition} ->
        permissions =
          Map.reject(definition.permissions, fn {_tool, permission} -> permission == :auto end)

        {name, %{definition | permissions: permissions}}
      end)

    %{definitions | by_name: held}
  end
end
