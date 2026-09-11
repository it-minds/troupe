defmodule Troupe.Telemetry do
  @moduledoc """
  Telemetry event names emitted by the harness.

    * `[:troupe, :llm, :request, :start | :stop]` — measurements `%{system_time}` /
      `%{duration}`; metadata `%{session_id, agent_path, model, ref}` plus `usage` on stop.
    * `[:troupe, :tool, :run, :start | :stop]` — metadata `%{session_id, agent_path, name, call_id}`.
    * `[:troupe, :agent, :transition]` — metadata `%{session_id, agent_path, from, to}`.
    * `[:troupe, :window, :transition]` — metadata `%{session_id, agent_path, from, to}`.
  """

  @spec start(list(), map()) :: integer()
  def start(name, meta) do
    :telemetry.execute(name ++ [:start], %{system_time: System.system_time()}, meta)
    System.monotonic_time()
  end

  @spec stop(list(), integer(), map()) :: :ok
  def stop(name, started_at, meta) do
    duration = System.monotonic_time() - started_at
    :telemetry.execute(name ++ [:stop], %{duration: duration}, meta)
  end

  @spec transition(:agent | :window, map()) :: :ok
  def transition(kind, meta) when kind in [:agent, :window] do
    :telemetry.execute([:troupe, kind, :transition], %{count: 1}, meta)
  end
end
