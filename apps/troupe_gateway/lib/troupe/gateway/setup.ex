defmodule Troupe.Gateway.Setup do
  @moduledoc """
  The first run in progress, held for the daemon's lifetime (Decision 705).

  `setup.get` and `setup.answer` are answered from here. The flow itself is
  `Troupe.Setup`, a value; this holds one, so that a screen can ask a question, close,
  and find the answers still there — and so that the key a person typed at one step is
  the key written at a later one, without ever travelling back to a client. Every move
  runs in the calling connection's process, so a provider that is slow to answer holds
  up that client and nobody else, and a crash there is that connection's.

  A finished flow is replaced with a fresh one at once: what it wrote is in the files
  and the record, and the next `setup.get` is a re-run, which is what the desktop app's
  Setup entry offers.
  """

  use Agent

  alias Troupe.Setup

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts), do: Agent.start_link(&Setup.new/0, name: __MODULE__)

  @doc "The flow as it stands, for `setup.get`."
  @spec get() :: map()
  def get, do: __MODULE__ |> Agent.get(& &1) |> Setup.report()

  @doc """
  Answer one step and keep the result. The finished flow is answered and let go of, so
  the caller reads the session it asked for from what comes back.
  """
  @spec answer(String.t(), map(), keyword()) :: {:ok, Setup.t()} | {:error, String.t()}
  def answer(step, answer, opts \\ []) do
    flow = Agent.get(__MODULE__, & &1)

    case Setup.answer(flow, step, answer, opts) do
      {:ok, %Setup{step: "done"} = finished} ->
        Agent.update(__MODULE__, fn _ -> Setup.new() end)
        {:ok, finished}

      {:ok, %Setup{} = next} ->
        Agent.update(__MODULE__, fn _ -> next end)
        {:ok, next}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
