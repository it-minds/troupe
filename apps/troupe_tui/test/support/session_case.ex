defmodule Troupe.SessionCase do
  @moduledoc """
  A session over a scratch workspace, driven by a scripted model.

  Every test gets its own workspace directory, its own state directory (so session
  logs never touch the developer's real one), and its own `Troupe.LLM.Fake` process,
  which is what lets these run `async: true`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Troupe.SessionCase
      alias Troupe.LLM.Fake
      alias Troupe.{Registry, Workspace}
    end
  end

  setup context do
    unique = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "troupe-test-#{unique}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)

    # State is isolated per test by passing the directory through config, not by
    # setting an environment variable: `System.put_env/2` is process-global, so with
    # `async: true` one test would redirect another test's session log.
    on_exit(fn -> File.rm_rf!(base) end)

    Map.merge(context, %{workspace: workspace, base: base, state_dir: state_dir})
  end

  @doc """
  Start a session whose model answers from `steps`.

  Returns `%{session, fake, workspace}`. The session and the fake are both cleaned up
  by ExUnit, so a test never has to remember to stop them.

  Use `:routes` instead of `:steps` whenever more than one agent will be asking:
  concurrent agents consume a shared list in a nondeterministic order.
  """
  @spec start_session(map(), keyword()) :: map()
  def start_session(context, opts \\ []) do
    # A unique child id, because a property test starts several sessions inside one
    # ExUnit test and the module name alone would collide.
    fake_spec =
      Supervisor.child_spec(
        {Troupe.LLM.Fake,
         steps: Keyword.get(opts, :steps, []),
         routes: Keyword.get(opts, :routes, %{}),
         default: Keyword.get(opts, :default, {:text, "done"}),
         delay_ms: Keyword.get(opts, :delay_ms, 0)},
        id: {Troupe.LLM.Fake, System.unique_integer([:positive])}
      )

    fake = ExUnit.Callbacks.start_supervised!(fake_spec)

    overrides =
      [
        provider: "fake",
        auto_approve: true,
        model: "fake-model",
        state_dir: context.state_dir
      ] ++ Keyword.get(opts, :config_overrides, [])

    {:ok, session} =
      Troupe.start_session(
        [
          workspace: context.workspace,
          fake: fake,
          config_overrides: overrides
        ] ++ Keyword.take(opts, [:agent, :task, :session_id, :definitions])
      )

    ExUnit.Callbacks.on_exit(fn -> Troupe.stop_session(session.id) end)

    %{session: session, fake: fake, workspace: context.workspace}
  end

  @doc "A file in the test workspace."
  @spec write_file(map(), Path.t(), iodata()) :: Path.t()
  def write_file(context, relative, contents) do
    path = Path.join(context.workspace, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  @spec read_file(map(), Path.t()) :: String.t()
  def read_file(context, relative), do: File.read!(Path.join(context.workspace, relative))

  @doc """
  Block until the root agent reaches one of `states`.

  Driven by subscribed events, not by sleeping: the caller must already be subscribed
  to the session.
  """
  @spec await_state(String.t(), [atom()], pos_integer()) :: :ok
  def await_state(session_id, states, timeout \\ 5_000) do
    receive do
      {:troupe_event, ^session_id,
       %{type: :agent_state, agent_path: ["root"], data: %{state: state}}} ->
        if state in states, do: :ok, else: await_state(session_id, states, timeout)
    after
      timeout ->
        raise "timed out waiting for root agent to reach one of #{inspect(states)}"
    end
  end

  @doc "Block until an event of `type` arrives from any agent, returning it."
  @spec await_event(String.t(), atom(), pos_integer()) :: map()
  def await_event(session_id, type, timeout \\ 5_000) do
    receive do
      {:troupe_event, ^session_id, %{type: ^type} = event} -> event
    after
      timeout -> raise "timed out waiting for a #{inspect(type)} event"
    end
  end

  @doc "Every event of a type persisted so far."
  @spec events_of_type(String.t(), String.t()) :: [map()]
  def events_of_type(session_id, type) do
    session_id |> Troupe.events() |> Enum.filter(&(&1["type"] == type))
  end

  @doc "The persisted event types in order, for asserting a whole sequence."
  @spec event_types(String.t()) :: [String.t()]
  def event_types(session_id), do: session_id |> Troupe.events() |> Enum.map(& &1["type"])
end
