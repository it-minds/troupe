defmodule Troupe.Worker.Proposals do
  @moduledoc """
  Where a session on this pod asks whether to propose something to its owner, and where
  their "never for this" goes (#1208): the plane, over the control link, naming the session
  and nothing about whose it is. The plane reads the team, the owner and what they said
  before off the session's row, so a pod asks only about a session it holds.

  Installed as `Troupe.Proposals`' host when the pod starts, beside the person's memory
  (`Troupe.Worker.Connections`). A pod whose link is down proposes nothing, and a never it
  could not send is refused with a sentence the owner reads.
  """

  alias Troupe.Worker.Plane.Link

  @timeout 10_000

  @doc "Install this pod as where its sessions check a proposal and keep a never."
  @spec install() :: :ok
  def install, do: Troupe.Proposals.install(&__MODULE__.check/2, &__MODULE__.never/3)

  @doc "Ask the plane whether `session_id` may propose `proposal`, and how."
  @spec check(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def check(session_id, proposal) do
    request("session.proposal.check", %{
      "session_id" => session_id,
      "proposal" => Map.take(proposal, ~w(kind key draft))
    })
  end

  @doc "Keep the owner's never for `kind` and `key`, said in `session_id`."
  @spec never(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def never(session_id, kind, key) do
    case request("session.proposal.never", %{
           "session_id" => session_id,
           "kind" => kind,
           "key" => key
         }) do
      {:ok, _kept} ->
        :ok

      {:error, %{"data" => %{"reason" => reason}}} when is_binary(reason) ->
        {:error, reason}

      {:error, %Troupe.Protocol.Error{data: %{reason: reason}}} when is_binary(reason) ->
        {:error, reason}

      {:error, _unreachable} ->
        {:error, "the plane could not be reached from this pod; try again later"}
    end
  end

  defp request(method, params) do
    case Process.whereis(Link) do
      nil -> {:error, :no_link}
      link -> Link.request(link, method, params, @timeout)
    end
  end
end
