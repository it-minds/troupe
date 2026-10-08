defmodule Troupe.Session.Shell do
  @moduledoc """
  A person's own commands in a session: `!cmd` in the TUI, `shell.run` on the wire
  (issue #486, Decision 813).

  A command runs where the session runs, in its workspace, through the runner the agent's
  `shell` tool uses (`Troupe.Tools.Shell.execute/3`): the same shell, reaper, sandbox,
  timeout and kill. Each runs in a task of its own under the session's `Task.Supervisor`,
  which sits above the agent so an agent that restarts leaves a running command alone,
  and which goes when the session does, taking every command it runs with it.

  What it says while it runs is ephemeral (`shell_started`, `shell_output`). When it ends,
  the root agent writes the durable `user_shell` and, unless the person kept it from the
  agent (`!!cmd`), holds `note/1` for its next model call: the output does not start a
  turn, and a command that ends in the middle of one waits for the next call rather than
  being spliced into a tool exchange.

  There is no approval prompt: the person typed it, and `control` plus being the session's
  owner is the authority, which the method checks. What forbids the agent's shell forbids
  this too (`refusal/2`).
  """

  alias Troupe.Agent.{Definition, Definitions}
  alias Troupe.Agent.Server, as: Agent
  alias Troupe.{Events, Registry, Session}
  alias Troupe.Session.Log
  alias Troupe.Tool.Ctx
  alias Troupe.Tools.{Output, Shell}

  require Logger

  # Output streamed live as `shell_output`, at most: a command that prints megabytes would
  # otherwise send every one of them to every client, and its tail arrives with `user_shell`.
  @stream_limit 1_048_576
  @root ["root"]

  @doc false
  def child_spec(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Supervisor.child_spec({Task.Supervisor, name: Registry.shell(session_id)}, id: __MODULE__)
  end

  @doc """
  Run `command` in the session's workspace and answer the run's id at once; what it does
  arrives as events. `opts`: `:actor`, who ran it; `:agent`, `false` to keep it from the
  agent (`!!cmd`); `:timeout_ms`, else the session's `shell_timeout_ms`; `:command_id`,
  carried on `user_shell`.

  `{:error, {:forbidden, setting, sentence}}` when the session's policy forbids it, and
  `{:error, :no_session}` when its tree is not running.
  """
  @spec run(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :no_session | {:forbidden, String.t(), String.t()}}
  def run(session_id, command, opts \\ []) do
    with {:ok, agent} <- root(session_id),
         {:ok, setup} <- setup(agent),
         nil <- refusal(setup.config, setup.definitions) do
      start(session_id, command, setup, opts)
    else
      {setting, sentence} when is_binary(setting) -> {:error, {:forbidden, setting, sentence}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Kill a command `run/3` started, and everything it started; it ends `killed`."
  @spec cancel(String.t(), String.t()) :: :ok | {:error, :not_running}
  def cancel(session_id, run_id) do
    case Registry.whereis({:shell_run, session_id, run_id}) do
      nil -> {:error, :not_running}
      pid -> Shell.kill(pid)
    end
  end

  @doc """
  Why this session may not run a person's command, as `{setting, sentence}`, or `nil`.

  The same things that forbid the agent's shell: a platform that allows only its own
  permission rules (`managed_permission_rules_only`), and agent definitions none of which
  may run `shell` at all. Every primary profile is asked, not only the one in use: a
  person who switched to `plan`, which reads and never runs, still has a shell, and an
  organisation that took the shell away took it from every profile it publishes.
  """
  @spec refusal(Troupe.Config.t(), Definitions.t()) :: {String.t(), String.t()} | nil
  def refusal(%{managed_permission_rules_only: true}, _definitions) do
    {"managed_permission_rules_only",
     "this platform allows only its own permission rules, so commands typed with ! are turned off here"}
  end

  def refusal(_config, definitions) do
    shell? =
      definitions
      |> Definitions.primaries()
      |> Enum.any?(
        &(Definition.permission(&1, Shell.name(), Shell.default_permission()) != :deny)
      )

    if not shell?,
      do:
        {"permissions",
         "no profile in this session may run shell commands, so commands typed with ! are refused too"}
  end

  @doc """
  What the agent is given of a `user_shell` before its next model call: that the person
  ran it, the command, its capped output and how it ended. A replay builds the same text
  from the same event.
  """
  @spec note(map()) :: String.t()
  def note(data) do
    output = if String.trim(data["output"] || "") == "", do: "(no output)", else: data["output"]

    """
    The person ran this command in the workspace themselves; it was not one of your tool calls.
    $ #{data["command"]}
    #{String.trim_trailing(output)}

    #{ending(data)}\
    """
  end

  defp ending(%{"ended" => "exited", "exit_status" => status}), do: "[exit status #{status}]"

  defp ending(%{"ended" => "timeout"} = data),
    do:
      "[timed out after #{seconds(data["timeout_ms"])}; the command and everything it started were killed]"

  defp ending(%{"ended" => "killed"}),
    do: "[stopped by the person; the command and everything it started were killed]"

  defp ending(data), do: "[it could not run: #{data["reason"] || "the shell is unavailable"}]"

  defp seconds(ms) when is_integer(ms), do: "#{Float.round(ms / 1000, 1)} s"
  defp seconds(_ms), do: "its timeout"

  defp root(session_id) do
    case Registry.agent_pid(session_id, Session.root_path()) do
      nil -> {:error, :no_session}
      pid -> {:ok, pid}
    end
  end

  defp setup(agent) do
    {:ok, Agent.shell_setup(agent)}
  catch
    :exit, _reason -> {:error, :no_session}
  end

  # The task says it is registered before the run's id is answered, so a cancel that
  # follows the answer at once always finds it.
  defp start(session_id, command, setup, opts) do
    run_id = "sh-" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
    caller = self()
    ref = make_ref()

    {:ok, _pid} =
      Task.Supervisor.start_child(Registry.shell(session_id), fn ->
        true = Registry.first?({:shell_run, session_id, run_id})
        send(caller, {ref, :registered})
        execute(session_id, run_id, command, setup, opts)
      end)

    receive do
      {^ref, :registered} -> {:ok, run_id}
    after
      5_000 -> {:error, :no_session}
    end
  end

  defp execute(session_id, run_id, command, setup, opts) do
    Process.set_label("troupe shell #{run_id}")
    agent? = Keyword.get(opts, :agent, true) != false
    timeout = Keyword.get(opts, :timeout_ms) || setup.config.shell_timeout_ms
    started = System.monotonic_time(:millisecond)

    publish(session_id, "shell_started", %{
      "run_id" => run_id,
      "command" => command,
      "agent" => agent?
    })

    result =
      Shell.execute(command, setup.workspace,
        timeout_ms: timeout,
        on_output: &stream(session_id, run_id, &1)
      )

    data =
      %{
        "run_id" => run_id,
        "command" => command,
        "agent" => agent?,
        "timeout_ms" => timeout,
        "duration_ms" => System.monotonic_time(:millisecond) - started
      }
      |> Map.merge(outcome(result, session_id, run_id, setup))
      |> put_present("command_id", Keyword.get(opts, :command_id))

    # Nothing is left to cancel once the end is written.
    Registry.release({:shell_run, session_id, run_id})
    ran(session_id, data, Keyword.get(opts, :actor))
  end

  # The tail, as the agent's own shell keeps it: capped at `tool_output_limit`, the whole
  # run kept as a blob of the session with a marker naming the `read_output` call.
  defp outcome({:ok, output, ending}, session_id, run_id, setup) do
    ctx = %Ctx{
      session_id: session_id,
      agent_path: @root,
      workspace: setup.workspace,
      call_id: run_id,
      agent_pid: self(),
      config: setup.config
    }

    output =
      output |> String.replace_invalid() |> Output.cap_tail(setup.config.tool_output_limit, ctx)

    case ending do
      status when is_integer(status) ->
        %{"output" => output, "ended" => "exited", "exit_status" => status}

      :timeout ->
        %{"output" => output, "ended" => "timeout"}

      :killed ->
        %{"output" => output, "ended" => "killed"}
    end
  end

  defp outcome({:error, reason}, _session_id, _run_id, _setup),
    do: %{"output" => "", "ended" => "failed", "reason" => reason}

  defp stream(session_id, run_id, chunk) do
    sent = Process.get(:troupe_shell_streamed, 0)
    Process.put(:troupe_shell_streamed, sent + byte_size(chunk))

    cond do
      sent >= @stream_limit ->
        :ok

      sent + byte_size(chunk) > @stream_limit ->
        text = binary_part(chunk, 0, @stream_limit - sent)

        publish(session_id, "shell_output", %{
          "run_id" => run_id,
          "text" =>
            String.replace_invalid(text) <>
              "\n[more output: its tail comes when the command ends]\n"
        })

      true ->
        publish(session_id, "shell_output", %{
          "run_id" => run_id,
          "text" => String.replace_invalid(chunk)
        })
    end
  end

  # The root agent writes `user_shell`, so the log and what it holds for its next call
  # agree. One restarting is waited for; a session that went before its agent came back
  # still has its log, and the record goes there, where a replay finds it.
  defp ran(session_id, data, actor, tries \\ 25)

  defp ran(session_id, data, actor, 0) do
    if Registry.whereis({:log, session_id}),
      do: Log.append(session_id, @root, :user_shell, data, actor)
  catch
    :exit, reason ->
      Logger.warning("troupe: #{data["run_id"]} ended unrecorded: #{inspect(reason)}")
  end

  defp ran(session_id, data, actor, tries) do
    case root(session_id) do
      {:ok, agent} -> Agent.shell_ran(agent, data, actor)
      {:error, :no_session} -> retry(session_id, data, actor, tries)
    end
  catch
    :exit, _reason -> retry(session_id, data, actor, tries)
  end

  defp retry(session_id, data, actor, tries) do
    Process.sleep(200)
    ran(session_id, data, actor, tries - 1)
  end

  defp publish(session_id, type, data),
    do: Events.publish_ephemeral(session_id, type, @root, data)

  defp put_present(data, _key, nil), do: data
  defp put_present(data, key, value), do: Map.put(data, key, value)
end
