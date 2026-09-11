defmodule Troupe.Operator.Fixtures do
  @moduledoc """
  The resources the tests reason about, as the API server would hand them over.

  Written as the maps a `WorkerProfile` or `TroupePolicy` decodes to rather than as
  structs, so the parsing is exercised too: a test that started from a struct would
  pass while the CRD's field names were wrong.
  """

  @doc "A policy that allows the profile below and not much else."
  @spec policy(keyword()) :: map()
  def policy(overrides \\ []) do
    spec =
      %{
        "allowedImageRepositories" => ["ghcr.io/objective-mj/troupe-worker"],
        "maxReplicas" => 4,
        "maxSessionsPerPod" => 8,
        "maxResources" => %{"cpu" => "2", "memory" => "4Gi"},
        "allowedEgress" => ["*.anthropic.com", "llm.internal.test", "github.com", "mcp.internal.test"],
        "allowedStorageClasses" => ["standard"],
        "orgVolume" => %{"storageClassName" => "standard", "size" => "5Gi"},
        "namespacePrefix" => "troupe-w-",
        "workersDomain" => "workers.example.test"
      }
      |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))

    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "TroupePolicy",
      "metadata" => %{"name" => "default"},
      "spec" => spec
    }
  end

  @doc "A profile inside that policy."
  @spec profile(keyword()) :: map()
  def profile(overrides \\ []) do
    spec =
      %{
        "image" => %{"repository" => "ghcr.io/objective-mj/troupe-worker", "tag" => "0.2.0"},
        "replicas" => 2,
        "sessionsPerPod" => 4,
        "resources" => %{
          "requests" => %{"cpu" => "500m", "memory" => "1Gi"},
          "limits" => %{"cpu" => "2", "memory" => "4Gi"}
        },
        "llm" => %{
          "endpoint" => "https://llm.internal.test/v1",
          "secretRef" => %{"name" => "llm-credentials", "key" => "api-key"}
        },
        "mcpServers" => [
          %{
            "name" => "tickets",
            "url" => "https://mcp.internal.test/tickets",
            "secretRef" => %{"name" => "mcp-tickets", "key" => "token"}
          }
        ],
        "egress" => %{"fqdns" => ["api.anthropic.com"], "gitHosts" => ["github.com"]},
        "configBundleChannel" => "stable",
        "orgMount" => true,
        "teams" => [
          %{"name" => "dev", "mode" => "rw", "storageClassName" => "standard", "size" => "20Gi"},
          %{"name" => "ux", "mode" => "ro", "storageClassName" => "standard", "size" => "5Gi"}
        ]
      }
      |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))

    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "WorkerProfile",
      "metadata" => %{
        "name" => "dev",
        "namespace" => "troupe-system",
        "uid" => "11111111-2222-3333-4444-555555555555",
        "generation" => 1
      },
      "spec" => spec
    }
  end

  @doc "Find one object in a manifest list."
  @spec find([map()], String.t(), String.t()) :: map() | nil
  def find(resources, kind, name) do
    Enum.find(resources, &(&1["kind"] == kind and get_in(&1, ["metadata", "name"]) == name))
  end

  @doc "Every object of a kind."
  @spec all([map()], String.t()) :: [map()]
  def all(resources, kind), do: Enum.filter(resources, &(&1["kind"] == kind))
end
