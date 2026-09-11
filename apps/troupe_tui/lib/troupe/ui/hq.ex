defmodule Troupe.UI.HQ do
  @moduledoc """
  Entry point for HQ, the fleet view.

  One screen for every session the principal can see, and one inbox for everything
  waiting on a person. In stage 1 that is the local daemon's sessions; the same screen
  is what later shows remote workers alongside them, because it is built on `fleet`
  and `session.list` rather than on anything local.
  """

  alias Troupe.UI.HQ.Server

  @doc "Run HQ against the daemon. Blocks until the user quits."
  @spec run(keyword()) :: non_neg_integer()
  def run(connect_opts \\ []) do
    case Server.start_link(connect: connect_opts, owner: self(), name: nil) do
      {:ok, pid} -> await(pid)
      :ignore -> fail(:no_terminal)
      {:error, reason} -> fail(reason)
    end
  end

  defp await(pid) do
    ref = Process.monitor(pid)

    receive do
      {:hq_exit, code} ->
        Process.demonitor(ref, [:flush])
        code

      {:DOWN, ^ref, :process, ^pid, :normal} ->
        0

      {:DOWN, ^ref, :process, ^pid, reason} ->
        IO.puts(:stderr, "troupe: HQ stopped: #{inspect(reason)}")
        1
    end
  end

  defp fail(reason) do
    IO.puts(:stderr, "troupe: could not start HQ: #{describe(reason)}")
    1
  end

  defp describe(:no_terminal), do: "no usable terminal"
  defp describe(reason), do: inspect(reason)
end
