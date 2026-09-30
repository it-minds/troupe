defmodule Troupe.Plane.ClusterPolicyTest do
  @moduledoc """
  The cluster's `TroupePolicy`, read on every call, and what the log says about it.

  A GitOps plane reads the policy at every pass, every fifteen seconds, and one with no
  policy to read logged a warning each time: the one line that mattered, the first, was
  buried under the same line four times a minute. So the log says when the policy stops
  being readable and when it is readable again, and nothing in between.
  """

  use Troupe.Plane.DataCase, async: false

  import ExUnit.CaptureLog

  alias Troupe.Plane.{ClusterPolicy, FakeCluster}
  alias Troupe.Policy

  setup do
    Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
    on_exit(fn -> Application.delete_env(:troupe_plane, :provisioning_mode) end)

    FakeCluster.start()
    :ok
  end

  test "a policy that cannot be read is said once, and so is its return" do
    # Readable first, whatever an earlier test left the plane believing.
    FakeCluster.put(policy())
    capture_log(fn -> assert %Policy{} = ClusterPolicy.current() end)

    FakeCluster.delete("TroupePolicy", "default")
    log = capture_log(fn -> for _pass <- 1..4, do: assert(ClusterPolicy.current() == nil) end)
    assert occurrences(log, "no TroupePolicy default could be read") == 1

    FakeCluster.put(policy())

    log =
      capture_log(fn -> for _pass <- 1..4, do: assert(%Policy{} = ClusterPolicy.current()) end)

    assert occurrences(log, "TroupePolicy default can be read again") == 1
    assert occurrences(log, "could be read:") == 0
  end

  defp occurrences(log, text), do: log |> String.split(text) |> length() |> Kernel.-(1)

  defp policy do
    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "TroupePolicy",
      "metadata" => %{"name" => "default"},
      "spec" => %{
        "allowedImageRepositories" => ["ghcr.io/troupe"],
        "allowedEgress" => ["gateway.example.test"],
        "namespacePrefix" => "troupe-w-"
      }
    }
  end
end
