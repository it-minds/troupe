defmodule Troupe.Plane.EnrolmentStub do
  @moduledoc """
  A stand-in for `TokenReview`, for tests that have no Kubernetes.

  A compiled module rather than a function defined in a test file, because a second
  replica is a separate OTP node and a test module exists only in the node that compiled
  it. This one is on the code path both nodes share.

  `Troupe.Plane.EnrolmentTest` proves the real thing against a real API server; what this
  is for is the tests where enrolment is scaffolding rather than the subject.
  """

  @doc """
  Accept `"<profile>-token"` as that profile, and nothing else.

  Shaped like the real answer — namespace derived from the profile, the worker service
  account — so a caller cannot accidentally depend on a shape production does not
  produce.
  """
  @spec verify(String.t()) :: {:ok, map()} | {:error, :unauthenticated}
  def verify(token) when is_binary(token) do
    case String.split(token, "-token") do
      [profile, ""] when profile != "" ->
        {:ok,
         %{
           profile: profile,
           namespace: "troupe-w-#{profile}",
           pod_name: nil,
           service_account: "troupe-worker"
         }}

      _ ->
        {:error, :unauthenticated}
    end
  end

  def verify(_token), do: {:error, :unauthenticated}
end
