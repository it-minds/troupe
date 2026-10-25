defmodule Troupe.Worker.MemoryRead do
  @moduledoc """
  How a pod's session asks, as its turn begins, whether the memory it holds is in force
  (#55): `session.memory.read` over the control link, with the session's id, its epoch and
  each document's scope, name, version and hash, never the text. The plane keeps that as
  what the turn runs under and answers with the documents in force where the session is
  behind, which the session takes before the turn starts. So a `session.memory` lost between
  two turns leaves no turn on the versions before it, and the console sees which sessions are
  behind.

  Installed as `Troupe.Session.PlaneMemory`'s check when the pod starts, beside
  `Troupe.Worker.UserMemory`. A link that is down, or a plane that does not answer within two
  seconds, leaves the session as it is: the turn runs on what it holds, and a pod's next
  activation carries the documents anyway.
  """

  alias Troupe.Session.PlaneMemory
  alias Troupe.Worker.Plane.Link
  alias Troupe.Worker.Sessions

  @timeout 2_000

  @doc "Install this pod as how a session's turn asks whether its memory is in force."
  @spec install() :: :ok
  def install, do: PlaneMemory.install_check(&__MODULE__.check/2)

  @doc "Ask the plane for one session: `{:ok, :current}`, `{:ok, documents}` or `{:error, reason}`."
  @spec check(String.t(), [map()]) :: {:ok, :current | [map()]} | {:error, term()}
  def check(session_id, stamps) do
    params =
      %{"session_id" => session_id, "documents" => stamps}
      |> then(&if epoch = Sessions.epoch(session_id), do: Map.put(&1, "epoch", epoch), else: &1)

    case request(params) do
      {:ok, %{"current" => false, "memory" => documents}} when is_list(documents) -> {:ok, documents}
      {:ok, %{"current" => true}} -> {:ok, :current}
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, _reason} = error -> error
    end
  end

  defp request(params) do
    case Process.whereis(Link) do
      nil -> {:error, :no_link}
      link -> Link.request(link, "session.memory.read", params, @timeout)
    end
  catch
    :exit, _gone -> {:error, :no_link}
  end
end
