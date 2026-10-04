defmodule Troupe.LLM.Catalog.Refresher do
  @moduledoc """
  Refreshes the model catalog in the background (Decision 778). A local session that
  starts hands its config here, and when `Troupe.LLM.Catalog.Store.stale/2` says the cache
  should be refreshed — the first run, a provider or base URL that changed, a list a day
  old, a provider due another try, a configured model the list does not have — the
  providers are asked in a process of their own. The session never waits: it started
  with the cache as it was, and the next one reads what this wrote.

  One refresh at a time. A session that starts while one runs is looked at again when it
  ends, the last such config only, since a refresh asks every provider a config names.

  Off with `config :troupe_core, catalog_refresh: false`, which the test suites set so
  that a test with a key in its config never asks a real provider for anything.
  """

  use GenServer

  alias Troupe.LLM.Catalog.Store

  require Logger

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Refresh the catalog for `config` if it is stale, in the background. Returns at once."
  @spec check(Troupe.Config.t()) :: :ok
  def check(config) do
    if Application.get_env(:troupe_core, :catalog_refresh, true),
      do: GenServer.cast(__MODULE__, {:check, config})

    :ok
  end

  @doc "Returns once no refresh is running or waiting: for a test."
  @spec await(timeout()) :: :ok
  def await(timeout \\ 60_000), do: GenServer.call(__MODULE__, :await, timeout)

  @impl GenServer
  def init(nil), do: {:ok, %{running: nil, next: nil, waiting: []}}

  @impl GenServer
  def handle_cast({:check, config}, %{running: nil} = state), do: {:noreply, run(state, config)}
  def handle_cast({:check, config}, state), do: {:noreply, %{state | next: config}}

  @impl GenServer
  def handle_call(:await, _from, %{running: nil} = state), do: {:reply, :ok, state}
  def handle_call(:await, from, state), do: {:noreply, %{state | waiting: [from | state.waiting]}}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{running: ref, next: nil} = state) do
    Enum.each(state.waiting, &GenServer.reply(&1, :ok))
    {:noreply, %{state | running: nil, waiting: []}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{running: ref, next: config} = state),
    do: {:noreply, run(%{state | running: nil, next: nil}, config)}

  def handle_info(_other, state), do: {:noreply, state}

  # Whether to ask is decided in the process that asks, so neither reading the cache nor
  # a provider that answers slowly holds up the next session's check.
  defp run(state, config) do
    {_pid, ref} = spawn_monitor(fn -> refresh(config) end)
    %{state | running: ref}
  end

  defp refresh(config) do
    with reason when reason != nil <- Store.stale(config),
         {:ok, catalog, failures} <- Store.refresh(config) do
      Logger.info("troupe: refreshed the model catalog (#{reason}): #{map_size(catalog)} models")

      Enum.each(failures, fn {name, why} ->
        Logger.warning(
          "troupe: the model catalog could not be refreshed from #{name}: #{inspect(why)}"
        )
      end)
    end
  end
end
