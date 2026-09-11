defmodule Troupe.UI.Headless do
  @moduledoc """
  The same event stream as the TUI, rendered as plain lines.

  For CI, scripting, and any terminal that is not one. It runs **in the calling
  process**: the command has nothing else to do while a turn is in flight, and a
  renderer that is also the caller needs no protocol of its own for "are we done yet".

  It is a subscriber and nothing more. Everything it knows, it learned from events;
  nothing in a session ever waits on it.
  """

  alias Troupe.Protocol.{Client, Event}

  defstruct quiet: false,
            streaming?: false,
            started?: false,
            errored?: false,
            code: nil

  @doc """
  Follow a session until its root agent finishes, printing as it goes.

  Returns an exit code: 0 when the run ended normally, 1 when it ended in an error or
  the budget ran out, and 124 on timeout — the code `timeout(1)` uses, so a CI step
  reads the same.
  """
  @spec run(pid(), String.t(), keyword()) :: non_neg_integer()
  def run(client, session_id, opts \\ []) do
    case Client.subscribe(client, "session:" <> session_id) do
      {:ok, _result} ->
        deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 300_000)
        send_task(client, session_id, Keyword.get(opts, :task))
        loop(%__MODULE__{quiet: Keyword.get(opts, :quiet, false)}, deadline)

      {:error, error} ->
        IO.puts(:stderr, "troupe: could not follow the session: #{error.message}")
        1
    end
  end

  # The task is sent *after* subscribing, so nothing it causes can arrive before we
  # are listening. Sent by `session.create` instead, it would race the subscription.
  defp send_task(_client, _session_id, nil), do: :ok

  defp send_task(client, session_id, task) do
    Client.call(client, "input.send", %{
      "command_id" => Client.command_id(),
      "session_id" => session_id,
      "text" => task
    })

    :ok
  end

  defp loop(state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      finish(state, 124)
    else
      receive do
        {:troupe_event, _topic, _session_id, %Event{} = event} ->
          state = state |> render(event) |> maybe_complete(event)

          case state.code do
            nil -> loop(state, deadline)
            code -> finish(state, code)
          end

        # Only ephemerals were dropped, and this renderer prints as it goes: there is
        # nothing to rebuild, so re-subscribing would lose more than it recovered.
        {:troupe_resync, _id, _topic, _last_seq} ->
          loop(state, deadline)

        {:troupe_disconnected, reason} ->
          newline(state)
          IO.puts(:stderr, "troupe: the daemon went away (#{inspect(reason)})")
          1
      after
        remaining -> finish(state, 124)
      end
    end
  end

  defp finish(state, code) do
    newline(state)
    code
  end

  # -- rendering --------------------------------------------------------------

  defp render(state, %Event{type: "llm_delta", data: %{"kind" => "text", "text" => text}}) do
    if state.quiet do
      state
    else
      IO.write(text)
      %{state | streaming?: true}
    end
  end

  defp render(state, %Event{type: "user_input", data: data}) do
    line(state, "\n#{prefix(data["source"])} #{first_line(data["text"])}")
  end

  defp render(state, %Event{type: "tool_call_started", data: data}) do
    line(state, "  → #{data["name"]} #{summarise(data["args"])}")
  end

  defp render(state, %Event{type: "tool_call_completed", data: %{"ok" => false} = data}) do
    line(state, "  ✗ #{data["name"]}: #{first_line(data["content"])}")
  end

  defp render(state, %Event{type: "tool_call_completed", data: data}) do
    line(state, "  ✓ #{data["name"]}")
  end

  defp render(state, %Event{type: "delegation_started", data: data}) do
    line(state, "  ⇢ delegate to #{data["agent"]}: #{first_line(data["task"])}")
  end

  defp render(state, %Event{type: "approval_requested", data: data}) do
    line(
      state,
      "  ? approval needed for #{data["tool"]} (#{data["call_id"]}) — " <>
        "run with --auto-approve in CI"
    )
  end

  defp render(state, %Event{type: "todo_updated", data: %{"items" => items}}) do
    line(state, "  ☰ task list:\n" <> indent(render_todos(items)))
  end

  defp render(state, %Event{type: "compacted"}) do
    line(state, "  … compacted earlier turns")
  end

  defp render(state, %Event{type: "watch_notice", data: data}) do
    line(state, "  · #{data["message"]}")
  end

  defp render(state, %Event{type: "llm_error", data: data}) do
    state
    |> line("  ! model request failed: #{data["reason"]}")
    |> Map.put(:errored?, true)
  end

  defp render(state, %Event{type: "cancelled"}), do: line(state, "  · cancelled")

  defp render(state, %Event{type: "budget_exhausted", data: data}) do
    line(state, "  ! budget exhausted (#{data["limit"]})")
  end

  defp render(state, %Event{}), do: state

  defp line(state, text) do
    # A streamed answer leaves the cursor mid-line; start a new one before printing
    # structure, or the two run together.
    state = newline(state)
    IO.puts(text)
    state
  end

  defp newline(%{streaming?: true} = state) do
    IO.write("\n")
    %{state | streaming?: false}
  end

  defp newline(state), do: state

  defp prefix("watch"), do: "[watch]"
  defp prefix("tui_todo_edit"), do: "[tasks]"
  defp prefix(_), do: ">"

  @markers %{
    "pending" => "[ ]",
    "in_progress" => "[~]",
    "completed" => "[x]",
    "cancelled" => "[-]"
  }

  defp render_todos([]), do: "(the task list is empty)"

  defp render_todos(items) do
    Enum.map_join(items, "\n", fn item ->
      marker = Map.get(@markers, item["status"], "[ ]")
      "#{marker} [#{item["id"]}] #{item["content"]}"
    end)
  end

  defp first_line(text) when is_binary(text) do
    text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 160)
  end

  defp first_line(other), do: inspect(other)

  defp summarise(args) when is_map(args) do
    args
    |> Enum.sort()
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{first_line(stringify(value))}" end)
    |> String.slice(0, 160)
  end

  defp summarise(other), do: inspect(other)

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)

  defp indent(text) do
    text |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))
  end

  # -- completion -------------------------------------------------------------

  # An agent publishes `idle` from init, before it has been given anything to do, so
  # "finished" has to mean "went busy, then came back" — otherwise a headless run
  # would report success before its own first turn.
  defp maybe_complete(state, %Event{type: "agent_state", agent: ["root"], data: data}) do
    case data["state"] do
      "done" ->
        %{state | code: if(data["done_reason"] in ["budget_exhausted", "error"], do: 1, else: 0)}

      "idle" when state.started? ->
        %{state | code: if(state.errored?, do: 1, else: 0)}

      "idle" ->
        state

      _busy ->
        %{state | started?: true}
    end
  end

  # Durable, and therefore the one signal that survives a client that fell behind.
  defp maybe_complete(state, %Event{type: "agent_done", agent: ["root"], data: data}) do
    %{state | code: if(data["reason"] in ["budget_exhausted", "error"], do: 1, else: 0)}
  end

  defp maybe_complete(state, %Event{}), do: state
end
