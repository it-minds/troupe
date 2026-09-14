defmodule Troupe.Worker.PlaneHelper do
  @moduledoc """
  Taking the plane away, for the worker tests that drive a real one.

  A script rather than a `.ex` beside the other support files, and required from
  `test_helper.exs`: `test/support` is on `elixirc_paths` in this environment, so a
  module there is compiled into `troupe_worker`'s beams, and `mix troupe.boundaries`
  reads those beams and — correctly — refuses a worker that calls the plane. The test
  files themselves are scripts and are not in the beams, which is how they have always
  been allowed to drive a plane; this belongs with them.
  """

  alias Troupe.Plane.Control.{Connections, Listener}

  @doc """
  Take the plane away the way a killed replica does, without taking the test's database
  connection with it.

  `Troupe.Plane.Control.Connection` does not trap exits, so the supervisor shutdown
  these tests use to simulate a killed replica kills it where it stands — and where it
  stands is sometimes inside a query. The sandbox hands every process one shared
  connection, so a client that exits mid-checkout takes that connection down with it,
  and the next plane process fails with an `OwnershipError` or a "client exited" a
  hundred lines from the `stop_supervised!` that caused it.

  `GenServer.stop/3` goes through the process's own loop instead: each connection
  finishes the callback it is in, runs `terminate/2`, and closes its socket. What the
  worker sees is the same either way — a socket that went.

  Every child of the supervisor, not `Connections.for_profile/1`: a connection registers
  itself at *enrolment*, not when the socket arrives, so one that is still proving which
  pod it is has no profile name and is in no registry. That is precisely the one that
  was still being killed mid-query, because enrolment is the part that writes.
  """
  @spec stop_plane() :: :ok
  def stop_plane do
    ExUnit.Callbacks.stop_supervised!(Listener)

    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(Connections), is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _already_gone -> :ok
      end
    end

    ExUnit.Callbacks.stop_supervised!(Connections)
    :ok
  end
end
