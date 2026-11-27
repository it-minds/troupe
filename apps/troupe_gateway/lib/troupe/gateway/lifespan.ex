defmodule Troupe.Gateway.Lifespan do
  @moduledoc """
  The daemon's pass over the throwaway sessions on this computer (#1209): soon after it
  starts, and every ten minutes while it runs, each local session marked throwaway and
  quiet for `throwaway_erase_after_hours` (`config.yaml`, 24 unless set, 1 to 168) is erased
  (`Troupe.Sessions.Lifespan.sweep/2`). A private one is the plane's to erase, and is left.

  A daemon that is not running erases nothing, so a session past its window goes at the
  first pass after the daemon next starts. A pass that raises is said and the next one tries
  again; the process is not taken down for it.
  """

  use GenServer

  alias Troupe.Sessions.Lifespan

  require Logger

  @first_ms 30_000
  @every_ms 10 * 60_000

  @hours_key {__MODULE__, :hours}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The window this daemon erases throwaway sessions after, in hours, as its last pass read
  it from the configuration: what a listing's `erases_at` is counted with.
  """
  @spec hours() :: pos_integer()
  def hours do
    case :persistent_term.get(@hours_key, nil) do
      nil -> remember_hours()
      hours -> hours
    end
  end

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe throwaway sweep")
    every = Keyword.get(opts, :every_ms, @every_ms)
    Process.send_after(self(), :pass, Keyword.get(opts, :first_ms, @first_ms))
    {:ok, %{every_ms: every}}
  end

  @impl GenServer
  def handle_info(:pass, state) do
    try do
      hours = remember_hours()

      Troupe.list_live_sessions(%{"state" => ["dormant"], "lifespan" => "throwaway"})
      |> Lifespan.sweep(hours: hours)
    rescue
      exception ->
        Logger.error("troupe: the throwaway sweep failed: #{Exception.message(exception)}")
    end

    Process.send_after(self(), :pass, state.every_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp remember_hours do
    hours = Lifespan.hours(config())
    :persistent_term.put(@hours_key, hours)
    hours
  end

  # The person's own configuration, read at each pass: a window changed takes effect at the
  # next without a restart. One that cannot be read is the default window.
  defp config do
    case Troupe.Config.resolve(nil, [], []) do
      {:ok, config, _layers} -> config
      {:error, _error} -> nil
    end
  end
end
