defmodule Mix.Tasks.Troupe.Usage do
  @shortdoc "Prices a session's LLM calls: tokens, cache hit ratio, cost-weighted input"

  @moduledoc """
  Prints what a session's calls cost, per call and in total, from its persisted
  event log — so two runs of the same task can be compared after the fact:

      mix troupe.usage                 # the most recent session in this workspace
      mix troupe.usage <session id>
      mix troupe.usage --list

  `weighted` is the prompt priced in units of full-price input tokens
  (`input + 1.25 × cache_write + 0.1 × cache_read`) and is the figure to compare;
  raw input tokens rise with caching rather than falling.
  """

  use Mix.Task

  alias Troupe.LLM.UsageLog
  alias Troupe.Session.{Index, Log}

  @impl true
  def run(argv) do
    {:ok, _} = Application.ensure_all_started(:troupe)
    workspace = File.cwd!()

    case argv do
      ["--list"] -> list(workspace)
      [sid] -> report(workspace, sid)
      [] -> latest(workspace)
      _ -> Mix.raise("usage: mix troupe.usage [--list | <session id>]")
    end
  end

  defp list(workspace) do
    case Index.list(workspace) do
      [] -> Mix.shell().info("no sessions for #{workspace}")
      sessions -> Enum.each(sessions, &Mix.shell().info("#{&1.session_id}  #{&1.title}"))
    end
  end

  defp latest(workspace) do
    case Index.list(workspace) do
      [%{session_id: sid} | _] -> report(workspace, sid)
      [] -> Mix.shell().info("no sessions for #{workspace}")
    end
  end

  defp report(workspace, sid) do
    events = Log.read_file(sid, Path.join(Troupe.Paths.session_dir(workspace, sid), "events.jsonl"))

    Mix.shell().info("session #{sid}")

    events
    |> Enum.filter(&(&1.type == :assistant_message))
    |> Enum.each(fn e ->
      usage = Map.get(e.data, :usage) || %{}
      Mix.shell().info("  #{e.agent_path}  " <> UsageLog.format(UsageLog.call(usage)))
    end)

    Mix.shell().info("total  " <> UsageLog.format(UsageLog.summary(events)))
  end
end
