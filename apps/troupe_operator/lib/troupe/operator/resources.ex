defmodule Troupe.Operator.Resources do
  @moduledoc """
  What a `WorkerProfile` means, as Kubernetes objects.

  A pure function from a profile, a policy and the installation's settings to the list
  of manifests that profile implies. All the decisions live here — how pods are
  addressed, what egress is opened, which volumes are bound at which mode — so they can
  be tested without a cluster, and the reconciler is left with apply-and-compare.

  Every object carries the same labels and an owner reference to the profile, so a
  listing can find what belongs to a profile and deleting the profile takes the rest
  with it.
  """

  alias Troupe.Operator.{Names, Policy, Profile, Settings}

  @doc "Every object a profile implies, in dependency order."
  @spec for_profile(Profile.t(), Policy.t(), Settings.t()) :: [map()]
  def for_profile(%Profile{} = profile, %Policy{} = policy, %Settings{} = settings) do
    namespace = Names.namespace(policy.namespace_prefix, profile.name)

    List.flatten([
      namespace(namespace, profile),
      service_account(namespace, profile),
      team_claims(namespace, profile),
      org_claim(namespace, profile, policy),
      headless_service(namespace, profile, policy),
      pod_services(namespace, profile, policy),
      pod_ingresses(namespace, profile, policy, settings),
      network_policy(namespace, profile, policy, settings),
      cilium_network_policy(namespace, profile, settings),
      pod_disruption_budget(namespace, profile, policy),
      stateful_set(namespace, profile, policy, settings)
    ])
  end

  @doc """
  The identities of everything `for_profile/3` produces, for pruning.

  Nothing in a worker namespace carries an owner reference, because it cannot: owner
  references may not cross namespaces, and the `WorkerProfile` lives in
  `troupe-system` while its objects live in `troupe-w-<profile>`. Kubernetes would
  treat such an owner as missing and garbage-collect the lot — which it did, once.

  So the operator prunes instead: it lists what carries its labels and deletes whatever
  is no longer in this set. That is what scaling a profile down has to do anyway, since
  an Ingress for a pod that no longer exists is not garbage collected by anything.
  """
  @spec identities([map()]) :: MapSet.t({String.t(), String.t(), String.t()})
  def identities(resources) do
    resources
    |> Enum.map(&{&1["apiVersion"], &1["kind"], get_in(&1, ["metadata", "name"])})
    |> MapSet.new()
  end

  # -- namespace and identity -------------------------------------------------

  defp namespace(namespace, profile) do
    %{
      "apiVersion" => "v1",
      "kind" => "Namespace",
      "metadata" => %{"name" => namespace, "labels" => Names.managed_labels(profile.name)}
    }
  end

  # `automountServiceAccountToken: false`, and the pod gets a *projected* token with
  # audience `troupe-plane` instead. A token scoped to one audience cannot be replayed
  # against the Kubernetes API, which is what makes a worker's enrolment credential
  # useless for anything else.
  defp service_account(namespace, profile) do
    %{
      "apiVersion" => "v1",
      "kind" => "ServiceAccount",
      "metadata" => metadata(Names.service_account(), namespace, profile),
      "automountServiceAccountToken" => false
    }
  end

  # -- storage ----------------------------------------------------------------

  # The claims that bind a team's shared volume into this namespace. A volume granted
  # `ro` is still claimed `ReadOnlyMany` rather than merely mounted read-only: the mode
  # is enforced by the cluster, not only by the pod spec that asks for it.
  defp team_claims(namespace, profile) do
    Enum.map(profile.teams, fn team ->
      claim(
        Names.team_claim(team.name),
        namespace,
        profile,
        team.storage_class,
        team.size || "10Gi",
        access_mode(team.mode)
      )
    end)
  end

  defp org_claim(_namespace, %Profile{org_mount: false}, _policy), do: []
  defp org_claim(_namespace, _profile, %Policy{org_volume: nil}), do: []

  defp org_claim(namespace, profile, %Policy{org_volume: org}) do
    [
      claim(
        Names.org_claim(),
        namespace,
        profile,
        Map.get(org, "storageClassName"),
        Map.get(org, "size", "10Gi"),
        "ReadOnlyMany"
      )
    ]
  end

  defp access_mode(:rw), do: "ReadWriteMany"
  defp access_mode(:ro), do: "ReadOnlyMany"

  defp claim(name, namespace, profile, storage_class, size, access_mode) do
    spec =
      %{
        "accessModes" => [access_mode],
        "resources" => %{"requests" => %{"storage" => size}}
      }
      |> put_unless_nil("storageClassName", storage_class)

    %{
      "apiVersion" => "v1",
      "kind" => "PersistentVolumeClaim",
      "metadata" => metadata(name, namespace, profile),
      "spec" => spec
    }
  end

  # -- services and addressing ------------------------------------------------

  defp headless_service(namespace, profile, policy) do
    %{
      "apiVersion" => "v1",
      "kind" => "Service",
      "metadata" => metadata(Names.workload(policy.namespace_prefix, profile.name), namespace, profile),
      "spec" => %{
        "clusterIP" => "None",
        "selector" => Names.labels(profile.name),
        "ports" => [%{"name" => "harness", "port" => 4000, "targetPort" => 4000}]
      }
    }
  end

  # One Service and one Ingress per pod, not one per profile. A session lives on
  # exactly one pod, so a load balancer that sent the second connection somewhere else
  # would split a session's clients across pods that cannot see each other's state.
  defp pod_services(namespace, profile, policy) do
    for ordinal <- 0..(profile.replicas - 1)//1 do
      selector =
        Names.labels(profile.name)
        |> Map.put("statefulset.kubernetes.io/pod-name", Names.pod(policy.namespace_prefix, profile.name, ordinal))

      %{
        "apiVersion" => "v1",
        "kind" => "Service",
        "metadata" => metadata(Names.pod_service(profile.name, ordinal), namespace, profile),
        "spec" => %{
          "selector" => selector,
          "ports" => [%{"name" => "harness", "port" => 4000, "targetPort" => 4000}]
        }
      }
    end
  end

  defp pod_ingresses(namespace, profile, policy, settings) do
    for ordinal <- 0..(profile.replicas - 1)//1 do
      host = Names.host(profile.name, ordinal, policy.workers_domain)

      spec =
        %{
          "ingressClassName" => settings.ingress_class_name,
          "rules" => [
            %{
              "host" => host,
              "http" => %{
                "paths" => [
                  %{
                    "path" => "/",
                    "pathType" => "Prefix",
                    "backend" => %{
                      "service" => %{
                        "name" => Names.pod_service(profile.name, ordinal),
                        "port" => %{"number" => 4000}
                      }
                    }
                  }
                ]
              }
            }
          ]
        }
        |> put_unless_nil("tls", tls(host, settings))

      %{
        "apiVersion" => "networking.k8s.io/v1",
        "kind" => "Ingress",
        "metadata" =>
          Names.pod_service(profile.name, ordinal)
          |> metadata(namespace, profile)
          |> put_in(["annotations"], %{
            # The harness connection is a long-lived WebSocket, not a request.
            "nginx.ingress.kubernetes.io/proxy-read-timeout" => "3600",
            "nginx.ingress.kubernetes.io/proxy-send-timeout" => "3600"
          }),
        "spec" => spec
      }
    end
  end

  defp tls(_host, %Settings{tls_secret_name: nil}), do: nil

  defp tls(host, %Settings{tls_secret_name: secret}) do
    [%{"hosts" => [host], "secretName" => secret}]
  end

  # -- network ----------------------------------------------------------------

  # Default-deny in both directions, then exactly what a worker needs. Standard
  # NetworkPolicy cannot express a hostname, so the FQDN destinations become a wide
  # rule here and a precise `CiliumNetworkPolicy` alongside where Cilium is present.
  # The gap is written down rather than hidden: a policy that silently allows more than
  # it says is worse than one that admits what it cannot do.
  defp network_policy(namespace, profile, policy, settings) do
    %{
      "apiVersion" => "networking.k8s.io/v1",
      "kind" => "NetworkPolicy",
      "metadata" => metadata(Names.workload(policy.namespace_prefix, profile.name), namespace, profile),
      "spec" => %{
        "podSelector" => %{"matchLabels" => Names.labels(profile.name)},
        "policyTypes" => ["Ingress", "Egress"],
        "ingress" => [
          %{
            "from" => [
              %{"namespaceSelector" => %{"matchLabels" => %{"troupe.dev/ingress" => "true"}}}
            ],
            "ports" => [%{"protocol" => "TCP", "port" => 4000}]
          }
        ],
        "egress" => egress_rules(settings)
      }
    }
  end

  defp egress_rules(settings) do
    [
      # DNS, without which none of the rest resolves.
      %{
        "to" => [%{"namespaceSelector" => %{}, "podSelector" => %{"matchLabels" => %{"k8s-app" => "kube-dns"}}}],
        "ports" => [%{"protocol" => "UDP", "port" => 53}, %{"protocol" => "TCP", "port" => 53}]
      },
      # The plane's control listener, which is never exposed through ingress.
      %{
        "to" => [%{"namespaceSelector" => %{"matchLabels" => %{"kubernetes.io/metadata.name" => settings.plane_namespace}}}],
        "ports" => [%{"protocol" => "TCP", "port" => settings.plane_control_port}]
      },
      # Everything outside the cluster: the LLM endpoint, the MCP servers, the git
      # hosts, OpenBao and object storage when they are external. Narrowed to the exact
      # names by the Cilium policy where that is available.
      %{
        "to" => [
          %{
            "ipBlock" => %{
              "cidr" => "0.0.0.0/0",
              "except" => ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"]
            }
          }
        ],
        "ports" => [%{"protocol" => "TCP", "port" => 443}, %{"protocol" => "TCP", "port" => 80}]
      }
    ]
  end

  defp cilium_network_policy(_namespace, _profile, %Settings{cilium_available: false}), do: []

  defp cilium_network_policy(namespace, profile, _settings) do
    patterns = Enum.map(Profile.egress_destinations(profile), &%{"matchName" => &1})

    [
      %{
        "apiVersion" => "cilium.io/v2",
        "kind" => "CiliumNetworkPolicy",
        "metadata" => metadata("troupe-egress", namespace, profile),
        "spec" => %{
          "endpointSelector" => %{"matchLabels" => Names.labels(profile.name)},
          "egress" => [
            %{"toFQDNs" => patterns},
            %{"toEndpoints" => [%{"matchLabels" => %{"k8s-app" => "kube-dns"}}]}
          ]
        }
      }
    ]
  end

  defp pod_disruption_budget(namespace, profile, policy) do
    %{
      "apiVersion" => "policy/v1",
      "kind" => "PodDisruptionBudget",
      "metadata" => metadata(Names.workload(policy.namespace_prefix, profile.name), namespace, profile),
      "spec" => %{
        # A pod holds live sessions, so at most one may be gone at a time — and a
        # single-replica profile is protected entirely, which is what an eviction
        # should have to argue with.
        "maxUnavailable" => 1,
        "selector" => %{"matchLabels" => Names.labels(profile.name)}
      }
    }
  end

  # -- the workload -----------------------------------------------------------

  defp stateful_set(namespace, profile, policy, settings) do
    name = Names.workload(policy.namespace_prefix, profile.name)

    %{
      "apiVersion" => "apps/v1",
      "kind" => "StatefulSet",
      "metadata" => metadata(name, namespace, profile),
      "spec" => %{
        "serviceName" => name,
        "replicas" => profile.replicas,
        "podManagementPolicy" => "Parallel",
        # A pod holds live sessions. Rolling it on an image change would kill work in
        # progress, so the profile reports `UpgradePending` and waits for a drain.
        "updateStrategy" => %{"type" => "OnDelete"},
        "selector" => %{"matchLabels" => Names.labels(profile.name)},
        "template" => %{
          "metadata" => %{"labels" => Names.labels(profile.name)},
          "spec" => pod_spec(profile, policy, settings)
        },
        "volumeClaimTemplates" => [
          %{
            "metadata" => %{"name" => Names.data_volume()},
            "spec" => %{
              "accessModes" => ["ReadWriteOnce"],
              "resources" => %{"requests" => %{"storage" => "20Gi"}}
            }
          }
        ]
      }
    }
  end

  defp pod_spec(profile, policy, settings) do
    %{
      "serviceAccountName" => Names.service_account(),
      "automountServiceAccountToken" => false,
      "securityContext" => %{
        "runAsNonRoot" => true,
        "runAsUser" => 1000,
        "fsGroup" => 1000,
        "seccompProfile" => %{"type" => "RuntimeDefault"}
      },
      "terminationGracePeriodSeconds" => settings.drain_timeout_seconds,
      "containers" => [container(profile, policy, settings)],
      "volumes" => volumes(profile)
    }
    |> put_unless_nil("imagePullSecrets", pull_secrets(settings))
  end

  defp pull_secrets(%Settings{image_pull_secrets: []}), do: nil
  defp pull_secrets(%Settings{image_pull_secrets: names}), do: Enum.map(names, &%{"name" => &1})

  defp container(profile, policy, settings) do
    %{
      "name" => "worker",
      "image" => profile.image,
      "imagePullPolicy" => "IfNotPresent",
      "ports" => [%{"name" => "harness", "containerPort" => 4000}],
      "env" => env(profile, policy, settings),
      "resources" => profile.resources,
      "volumeMounts" => volume_mounts(profile),
      "readinessProbe" => probe("/health/ready"),
      "livenessProbe" => probe("/health/live"),
      "securityContext" => %{
        "allowPrivilegeEscalation" => false,
        "readOnlyRootFilesystem" => false,
        # `bubblewrap` needs user namespaces, not privileges: every capability is
        # dropped and the sandbox is built from unprivileged namespaces.
        "capabilities" => %{"drop" => ["ALL"]}
      }
    }
  end

  defp probe(path) do
    %{
      "httpGet" => %{"path" => path, "port" => 4000},
      "initialDelaySeconds" => 5,
      "periodSeconds" => 5
    }
  end

  defp env(profile, policy, settings) do
    base = [
      %{"name" => "TROUPE_PROFILE", "value" => profile.name},
      %{"name" => "TROUPE_NAMESPACE", "value" => Names.namespace(policy.namespace_prefix, profile.name)},
      %{"name" => "TROUPE_WORKERS_DOMAIN", "value" => policy.workers_domain},
      %{"name" => "TROUPE_PLANE_CONTROL", "value" => "#{settings.plane_control_host}:#{settings.plane_control_port}"},
      %{"name" => "TROUPE_BAO_ADDR", "value" => settings.bao_address},
      %{"name" => "TROUPE_OBJECT_ENDPOINT", "value" => settings.object_store_endpoint},
      %{"name" => "TROUPE_OBJECT_BUCKET", "value" => settings.object_store_bucket},
      %{"name" => "TROUPE_SESSIONS_PER_POD", "value" => to_string(profile.sessions_per_pod)},
      %{"name" => "TROUPE_CONFIG_CHANNEL", "value" => profile.config_bundle_channel},
      %{
        "name" => "TROUPE_POD_ORDINAL",
        "valueFrom" => %{"fieldRef" => %{"fieldPath" => "metadata.name"}}
      }
    ]

    base ++ llm_env(profile)
  end

  defp llm_env(%Profile{llm_endpoint: nil}), do: []

  defp llm_env(profile) do
    endpoint = [%{"name" => "TROUPE_BASE_URL", "value" => profile.llm_endpoint}]

    key =
      if profile.llm_secret_name do
        [
          %{
            "name" => "TROUPE_API_KEY",
            "valueFrom" => %{
              "secretKeyRef" => %{"name" => profile.llm_secret_name, "key" => profile.llm_secret_key}
            }
          }
        ]
      else
        []
      end

    endpoint ++ key
  end

  # The projected token is the pod's enrolment credential, and the only one it has.
  defp volumes(profile) do
    token = %{
      "name" => "enrolment-token",
      "projected" => %{
        "sources" => [
          %{
            "serviceAccountToken" => %{
              "path" => "token",
              "audience" => Names.enrolment_audience(),
              "expirationSeconds" => 3600
            }
          }
        ]
      }
    }

    team_volumes =
      Enum.map(profile.teams, fn team ->
        %{
          "name" => Names.team_claim(team.name),
          "persistentVolumeClaim" => %{
            "claimName" => team.claim_name || Names.team_claim(team.name),
            "readOnly" => team.mode == :ro
          }
        }
      end)

    org =
      if profile.org_mount do
        [
          %{
            "name" => Names.org_claim(),
            "persistentVolumeClaim" => %{"claimName" => Names.org_claim(), "readOnly" => true}
          }
        ]
      else
        []
      end

    [token] ++ team_volumes ++ org
  end

  defp volume_mounts(profile) do
    base = [
      %{"name" => Names.data_volume(), "mountPath" => "/var/lib/troupe"},
      %{"name" => "enrolment-token", "mountPath" => "/var/run/secrets/troupe", "readOnly" => true}
    ]

    teams =
      Enum.map(profile.teams, fn team ->
        %{
          "name" => Names.team_claim(team.name),
          "mountPath" => "/mnt/teams/#{team.name}",
          "readOnly" => team.mode == :ro
        }
      end)

    org =
      if profile.org_mount do
        # Always read-only, whatever the profile asked for. The org volume is the one
        # mount several teams share, and a writable shared mount is a channel between
        # them.
        [%{"name" => Names.org_claim(), "mountPath" => "/mnt/org", "readOnly" => true}]
      else
        []
      end

    base ++ teams ++ org
  end

  # -- helpers ----------------------------------------------------------------

  defp metadata(name, namespace, profile) do
    %{"name" => name, "namespace" => namespace, "labels" => Names.managed_labels(profile.name)}
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
