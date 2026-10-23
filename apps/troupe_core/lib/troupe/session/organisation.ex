defmodule Troupe.Session.Organisation do
  @moduledoc """
  What a change to the organisation's document gave a session already running (#657).

  A session's configuration is resolved once, as it starts, the organisation's defaults
  and limits among its layers (`Troupe.Config.Org`). When the plane's document changes, a
  person's machine learns it within a minute (the daemon asks the plane again while it is
  signed in) and keeps the new copy; then every session running here is resolved again by
  this process, from the same workspace and overrides it started with
  (`Troupe.Session.reconfigure/2`). Where a value the organisation sets, or holds a layer
  to, came out different, the new configuration and the keys that changed are kept here,
  and the session's root agent takes them as its next turn begins, never during one, and
  says so in a line (`config_note`, key `organisation`). The same values again change
  nothing and say nothing.

  Taken at a turn: what the agent reads from its configuration at each model call and each
  tool call (the model and provider, the limits it is held to, the tools' own limits) and
  its budget's limits, its use so far kept. What was set up as the session started (its
  approval mode, its MCP servers, its watchers) holds until it is started again, and the
  line names those keys apart.

  Placed above the agent, as `Session.ClientTools` is, so what was given outlives an
  agent's restart. Its name carries what was given beside it, so a reader, as
  `Troupe.Session.resolved/1` is, asks the registry and not this process.
  """

  use GenServer

  alias Troupe.Config.Explain
  alias Troupe.Registry

  # Set up as the session started, by the processes beside the agent: these hold until it
  # is started again, whatever the organisation now says.
  @at_start ~w(approvals auto_approve managed_permission_rules_only managed_mcp_servers_only
               personal_tools_forbidden_by watch watch_debounce_ms watch_poll_interval_ms
               watch_auto_approve fs_events fs_debounce_ms mcp)

  @typedoc "What a session was given: its configuration resolved again, and why."
  @type given :: %{
          config: Troupe.Config.t(),
          layers: Troupe.Config.Layers.Result.t(),
          keys: [String.t()],
          held: [String.t()],
          revision: pos_integer()
        }

  @doc false
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Elixir.Registry, {Registry, key(session_id), nil}}
    )
  end

  @doc """
  Resolve a running session's configuration again, and keep it for its agent's next turn
  where a value the organisation sets came out different. `{:ok, keys}` naming them, `[]`
  for none, or `{:error, :no_session}`.
  """
  @spec reconfigure(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def reconfigure(session_id) do
    case Registry.whereis(key(session_id)) do
      nil -> {:error, :no_session}
      pid -> GenServer.call(pid, :reconfigure, 30_000)
    end
  catch
    :exit, _gone -> {:error, :no_session}
  end

  @doc """
  Every session running here resolved again: what a person's machine does when its copy of
  the organisation's document changes, since every session on it reads that copy. Answers
  how many sessions took a change.
  """
  @spec reconfigure_all() :: non_neg_integer()
  def reconfigure_all do
    Registry
    |> Elixir.Registry.select([{{{:organisation, :"$1"}, :_, :_}, [], [:"$1"]}])
    |> Enum.count(&match?({:ok, [_ | _]}, reconfigure(&1)))
  end

  @doc "What the session was last given since it started, or `nil` for nothing since."
  @spec given(String.t()) :: given() | nil
  def given(session_id), do: Registry.value(key(session_id))

  @doc """
  The line a session says when its agent takes what it was given: the keys now in force,
  and those that hold until the session is started again.
  """
  @spec line(given()) :: String.t()
  def line(%{keys: keys, held: held}) do
    taken = keys -- held

    now =
      if taken == [],
        do: [],
        else: [
          "#{Enum.join(taken, ", ")} #{if length(taken) == 1, do: "holds", else: "hold"} from this turn"
        ]

    later =
      if held == [],
        do: [],
        else: ["#{Enum.join(held, ", ")} when the session is started again"]

    "Your organisation's settings changed: " <> Enum.join(now ++ later, "; ") <> "."
  end

  defp key(session_id), do: {:organisation, session_id}

  # -- server -------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Process.set_label("troupe organisation #{session_id}")

    {:ok,
     %{
       session_id: session_id,
       workspace: Keyword.fetch!(opts, :workspace),
       resolve: Keyword.get(opts, :resolve, []),
       revision: 0
     }}
  end

  @impl GenServer
  def handle_call(:reconfigure, _from, state) do
    with {:ok, config, layers} <- Troupe.Session.reconfigure(state.workspace, state.resolve),
         before when not is_nil(before) <- layers_before(state.session_id),
         [_ | _] = keys <- changed(before, layers) do
      revision = state.revision + 1
      held = Enum.filter(keys, &(top(&1) in @at_start))
      given = %{config: config, layers: layers, keys: keys, held: held, revision: revision}

      {_given, _before} =
        Elixir.Registry.update_value(Registry, key(state.session_id), fn _before -> given end)

      {:reply, {:ok, keys}, %{state | revision: revision}}
    else
      {:error, _reason} = error -> {:reply, error, state}
      _same -> {:reply, {:ok, []}, state}
    end
  end

  # What the session runs with now: what it was last given, or what it started with.
  defp layers_before(session_id) do
    case given(session_id) do
      %{layers: layers} -> layers
      nil -> Registry.value({:session, session_id})[:layers]
    end
  end

  # The keys whose value in force differs, where the organisation set it, before or after:
  # its defaults where nothing nearer sets the key, and its limits.
  defp changed(before, now) do
    was = Map.new(Explain.rows(before), &{&1.key, &1})
    is = Map.new(Explain.rows(now), &{&1.key, &1})

    (Map.keys(was) ++ Map.keys(is))
    |> Enum.uniq()
    |> Enum.filter(fn key ->
      a = Map.get(was, key)
      b = Map.get(is, key)
      value(a) != value(b) and (organisation?(a) or organisation?(b))
    end)
    |> Enum.sort()
  end

  defp value(nil), do: nil
  defp value(row), do: row.value

  defp organisation?(%{layer: layer}), do: layer in [:org, :enforced]
  defp organisation?(nil), do: false

  defp top(key), do: key |> String.split(".") |> hd()
end
