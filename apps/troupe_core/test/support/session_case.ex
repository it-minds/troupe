defmodule Troupe.SessionCase do
  @moduledoc """
  A session over a scratch workspace, driven by a scripted model.

  Every test gets its own workspace directory, its own state directory (so session
  logs never touch the developer's real one), and its own `Troupe.LLM.Fake` process,
  which is what lets these run `async: true`.

  Events reaching a test are `%Troupe.Protocol.Event{}` — the same struct a client
  sees over the wire, with string-keyed JSON data. A test that asserts on the old
  in-VM shape would be asserting on something no client can observe.
  """

  use ExUnit.CaseTemplate

  alias Troupe.Protocol.Event

  using do
    quote do
      import Troupe.SessionCase
      alias Troupe.LLM.Fake
      alias Troupe.Protocol.Event
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

  Use `:routes` instead of `:steps` whenever more than one agent will be asking:
  concurrent agents consume a shared list in a nondeterministic order.
  """
  @spec start_session(map(), keyword()) :: map()
  def start_session(context, opts \\ []) do
    fake_spec =
      Supervisor.child_spec(
        {Troupe.LLM.Fake,
         steps: Keyword.get(opts, :steps, []),
         routes: Keyword.get(opts, :routes, %{}),
         default: Keyword.get(opts, :default, {:text, "done"}),
         delay_ms: Keyword.get(opts, :delay_ms, 0),
         cache_read: Keyword.get(opts, :cache_read, 0),
         # `nil` is a gateway that reports no cost, which is every gateway on a streamed
         # response.
         cost_micros: Keyword.get(opts, :cost_micros, :derived)},
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
        [workspace: context.workspace, fake: fake, config_overrides: overrides] ++
          Keyword.take(opts, [:agent, :task, :session_id, :definitions, :bundle, :kind, :origin, :parent])
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
    wanted = Enum.map(states, &to_string/1)

    receive do
      {:troupe_event, ^session_id,
       %Event{type: "agent_state", agent: ["root"], data: %{"state" => state}}} ->
        if state in wanted, do: :ok, else: await_state(session_id, states, timeout)
    after
      timeout ->
        raise "timed out waiting for the root agent to reach one of #{inspect(states)}"
    end
  end

  @doc "Block until an event of `type` arrives from any agent, returning it."
  @spec await_event(String.t(), atom() | String.t(), pos_integer()) :: Event.t()
  def await_event(session_id, type, timeout \\ 5_000) do
    wanted = to_string(type)

    receive do
      {:troupe_event, ^session_id, %Event{type: ^wanted} = event} -> event
    after
      timeout -> raise "timed out waiting for a #{wanted} event"
    end
  end

  @doc "Every persisted event of a type."
  @spec events_of_type(String.t(), atom() | String.t()) :: [Event.t()]
  def events_of_type(session_id, type) do
    wanted = to_string(type)
    session_id |> Troupe.events() |> Enum.filter(&(&1.type == wanted))
  end

  @doc "The persisted event types in order, for asserting a whole sequence."
  @spec event_types(String.t()) :: [String.t()]
  def event_types(session_id), do: session_id |> Troupe.events() |> Enum.map(& &1.type)
end
