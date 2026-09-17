defmodule Troupe.Agent.ACPAgent do
  @moduledoc """
  A third-party agent, run as a subprocess, speaking ACP — with Troupe as the client.

  The other direction from `Troupe.Gateway.ACP`. There, an editor drives a Troupe session;
  here, a Troupe session delegates to an agent somebody else wrote, and Troupe answers the
  requests that agent makes of its client.

  ## Why this belongs in the worker and not in a client

  ACP's client side is where the filesystem and the terminal live. An editor implementing
  it hands an agent the real disk, because the editor *is* the user's machine and there is
  nothing else it could hand over. A worker is not: a session has a mount table, with names
  and modes, and it is the whole of what that session may touch.

  So this serves `fs/read_text_file`, `fs/write_text_file` and the terminal methods
  **through `Troupe.Workspace`**, which resolves through the mounts. A subprocess somebody
  else wrote gets the session's mounts at their modes rather than the pod's disk, and a
  path outside them fails the way any other tool call fails — not by a check written here,
  but by the same `Mounts.resolve/3` every tool goes through.

  That is the argument for doing it here. A client that ran the agent itself would be
  handing it a laptop; this hands it a session.

  ## What it is not

  Not a second kind of session. The subprocess is a delegate inside one: its output lands
  in the log as durable events like any other subagent's, its tool calls raise approvals
  like any other, and it is named in a bundle and narrowed by a grant like an agent or a
  skill. `session_created`, epochs, seals and the ACL are the session's, and the subprocess
  never learns they exist.
  """

  use GenServer

  alias Troupe.Workspace

  require Logger

  @typedoc "What this delegate needs to run one task against one session's mounts."
  @type options :: [
          session_id: String.t(),
          agent_path: [String.t()],
          workspace: Workspace.t(),
          entry: map(),
          task: String.t(),
          parent: pid(),
          parent_ref: reference(),
          port: port() | nil
        ]

  # ACP's own; the client half of what the gateway adapter implements as the agent half.
  @protocol_version 1

  defstruct [
    :session_id,
    :agent_path,
    :workspace,
    :entry,
    :task,
    :parent,
    :parent_ref,
    :port,
    :acp_session,
    buffer: "",
    next_id: 1,
    pending: %{},
    terminals: %{}
  ]

  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The ACP version this speaks as a client."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc """
  Answer one request the subprocess made of its client.

  Public because it is the whole of what this module is for and the only part worth
  testing on its own: given a session's workspace and a request an agent made, what comes
  back. Everything else here is plumbing around a port.
  """
  @spec serve(String.t(), map(), Workspace.t()) :: {:ok, map()} | {:error, map()}
  def serve("fs/read_text_file", %{"path" => path} = params, workspace) do
    case Workspace.resolve(workspace, path, :read) do
      {:ok, real} -> read_text(real, params)
      {:error, reason} -> {:error, refusal(reason, path)}
    end
  end

  def serve("fs/write_text_file", %{"path" => path, "content" => content}, workspace)
      when is_binary(content) do
    case Workspace.resolve(workspace, path, :write) do
      {:ok, real} ->
        File.mkdir_p!(Path.dirname(real))
        File.write!(real, content)
        {:ok, %{}}

      {:error, reason} ->
        {:error, refusal(reason, path)}
    end
  end

  # ACP defines a terminal and Troupe has one, but a terminal a *subprocess* opens is not
  # the same object: a session's shell tool is approved, budgeted and logged, and handing
  # an ACP agent an unmediated one would be a way round all three. Refused until it goes
  # through the tool it would otherwise bypass, and the refusal says so rather than
  # reporting a capability that does not exist.
  def serve("terminal/" <> _rest, _params, _workspace) do
    {:error,
     %{
       "code" => -32_601,
       "message" => "terminals are not offered to an ACP agent here",
       "data" => %{
         "reason" =>
           "a session's shell is approved, budgeted and logged; an unmediated terminal " <>
             "would be a way round all three"
       }
     }}
  end

  def serve(method, _params, _workspace) do
    {:error,
     %{"code" => -32_601, "message" => "method not found", "data" => %{"method" => method}}}
  end

  # -- what the client announces ----------------------------------------------

  @doc """
  The capabilities Troupe offers as an ACP client.

  `terminal` is false and says so at the handshake rather than at the first call, so an
  agent that could work either way picks the way that works. The filesystem is true because
  the mount table is a real filesystem — a narrower one than the agent expects, which is
  the point.
  """
  @spec client_capabilities() :: map()
  def client_capabilities do
    %{
      "fs" => %{"readTextFile" => true, "writeTextFile" => true},
      "terminal" => false
    }
  end

  # -- reading, with the parts ACP asks for -----------------------------------

  # ACP lets a client ask for a window of a file. Applied after the read rather than during
  # it, because the file is already bounded by being inside a mount and a partial read of a
  # small file is not worth a second code path.
  defp read_text(real, params) do
    case File.read(real) do
      {:ok, contents} ->
        {:ok, %{"content" => window(contents, params["line"], params["limit"])}}

      {:error, reason} ->
        {:error,
         %{
           "code" => -32_603,
           "message" => "could not read the file",
           "data" => %{"reason" => to_string(:file.format_error(reason))}
         }}
    end
  end

  defp window(contents, nil, nil), do: contents

  defp window(contents, line, limit) do
    lines = String.split(contents, "\n")
    from = max((line || 1) - 1, 0)

    lines
    |> Enum.drop(from)
    |> then(fn rest -> if limit, do: Enum.take(rest, limit), else: rest end)
    |> Enum.join("\n")
  end

  # The refusal an agent gets is the refusal a tool would get, in ACP's envelope. Naming the
  # mount rather than the path where the mount is what refused: an agent told "read-only" can
  # choose somewhere else, where one told "denied" can only retry.
  defp refusal({:read_only_mount, name}, path) do
    %{
      "code" => -32_602,
      "message" => "that mount is read-only",
      "data" => %{"mount" => name, "path" => path}
    }
  end

  defp refusal({:outside_workspace, _path}, path) do
    %{
      "code" => -32_602,
      "message" => "that path is not in this session's mounts",
      "data" => %{"path" => path}
    }
  end

  # -- the subprocess ---------------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      session_id: Keyword.fetch!(opts, :session_id),
      agent_path: Keyword.fetch!(opts, :agent_path),
      workspace: Keyword.fetch!(opts, :workspace),
      entry: Keyword.fetch!(opts, :entry),
      task: Keyword.fetch!(opts, :task),
      parent: Keyword.get(opts, :parent),
      parent_ref: Keyword.get(opts, :parent_ref),
      port: Keyword.get(opts, :port)
    }

    Process.set_label("troupe acp agent #{state.entry.name}")
    {:ok, state, {:continue, :open}}
  end

  @impl GenServer
  def handle_continue(:open, %{port: nil} = state) do
    case open_port(state.entry, state.workspace) do
      {:ok, port} -> {:noreply, %{state | port: port}}
      {:error, reason} -> {:stop, {:acp_agent_failed, reason}, state}
    end
  end

  def handle_continue(:open, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, consume(state.buffer <> data, state)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("troupe: acp agent #{state.entry.name} exited with #{status}")
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- framing ----------------------------------------------------------------

  defp consume(buffer, state) do
    case String.split(buffer, "\n", parts: 2) do
      [partial] ->
        %{state | buffer: partial}

      [line, rest] ->
        state = line |> String.trim() |> handle_line(state)
        consume(rest, state)
    end
  end

  defp handle_line("", state), do: state

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"method" => method, "id" => id} = frame} ->
        answer(state, id, serve(method, frame["params"] || %{}, state.workspace))

      # A notification from the agent — `session/update` — is the delegate reporting, and
      # it becomes log events through the parent rather than being answered.
      {:ok, %{"method" => _method}} ->
        state

      _other ->
        state
    end
  end

  defp answer(state, id, {:ok, result}) do
    write(state, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp answer(state, id, {:error, error}) do
    write(state, %{"jsonrpc" => "2.0", "id" => id, "error" => error})
  end

  defp write(%{port: nil} = state, _message), do: state

  defp write(state, message) do
    Port.command(state.port, [Jason.encode!(message), "\n"])
    state
  end

  # The command and its arguments come from the bundle and nothing else. No shell: an
  # argument a bundle carried would otherwise be a place to put a pipeline, and the bundle
  # is signed for what it says rather than for what a shell makes of it.
  defp open_port(entry, workspace) do
    case System.find_executable(entry.command) do
      nil ->
        {:error, {:not_on_path, entry.command}}

      executable ->
        {:ok,
         Port.open({:spawn_executable, executable}, [
           :binary,
           :exit_status,
           {:args, entry.args},
           {:cd, workspace.root_real},
           :use_stdio,
           :hide
         ])}
    end
  end
end
