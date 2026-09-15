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

  alias Troupe.Operator.{Names, Settings}
  alias Troupe.Policy
  alias Troupe.WorkerProfile, as: Profile
  alias Troupe.WorkerProfile.MCPServer

  # Where a worker keeps everything it can rebuild: sealed segments, materialised
  # bundles, restored workspaces. The mount and `TROUPE_STATE_HOME` have to name the same
  # directory, so they name the same constant.
  @state_dir "/var/lib/troupe"

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

  # `troupe.dev/workers=true` is what the plane's own NetworkPolicy selects on: the
  # control port is open to namespaces carrying it and to nothing else in the cluster.
  # It is put here rather than in `Names.managed_labels/1` because it says something
  # about the namespace — workers live in it — and nothing about the objects inside.
  defp namespace(namespace, profile) do
    labels = Map.put(Names.managed_labels(profile.name), "troupe.dev/workers", "true")

    %{
      "apiVersion" => "v1",
      "kind" => "Namespace",
      "metadata" => %{"name" => namespace, "labels" => labels}
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
  #
  # Named by `team_claim_name/1`, the same expression the pod's volume uses. They were
  # two expressions that had to agree and did not: the plane projects a `claimName` of
  # `troupe-team-<name>`, the mount preferred it, and creation always used the operator's
  # own `team-<name>`. So the operator created one claim and mounted another, and the
  # pod stuck at `persistentvolumeclaim "troupe-team-…" not found` — a pod that cannot be
  # scheduled at all, which is every session on that profile.
  # What the plane declared, or the operator's own name when it declared nothing. One
  # expression, so the claim that is created and the claim that is mounted cannot differ.
  defp team_claim_name(team), do: team.claim_name || Names.team_claim(team.name)

  defp team_claims(namespace, profile) do
    Enum.map(profile.teams, fn team ->
      claim(
        team_claim_name(team),
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
      "metadata" =>
        metadata(Names.workload(policy.namespace_prefix, profile.name), namespace, profile),
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
        |> Map.put(
          "statefulset.kubernetes.io/pod-name",
          Names.pod(policy.namespace_prefix, profile.name, ordinal)
        )

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
        |> put_unless_nil("tls", tls(profile.name, ordinal, host, settings))

      %{
        "apiVersion" => "networking.k8s.io/v1",
        "kind" => "Ingress",
        "metadata" =>
          Names.pod_service(profile.name, ordinal)
          |> metadata(namespace, profile)
          |> put_unless_nil("annotations", ingress_annotations(settings)),
        "spec" => spec
      }
    end
  end

  # Two ways to have a certificate, and the issuer wins where both are configured.
  #
  # With a cert-manager issuer each pod gets its own certificate for its own hostname,
  # in its own secret, over HTTP-01 — which works wherever the hostname already resolves
  # to the ingress controller, and therefore on any DNS host. Without one, every pod
  # shares a secret somebody else put in the namespace, which in practice is a wildcard
  # for `*.workers.<domain>` and can only be issued over DNS-01.
  defp tls(profile, ordinal, host, %Settings{cert_issuer: issuer}) when is_binary(issuer) do
    [%{"hosts" => [host], "secretName" => "#{Names.pod_service(profile, ordinal)}-tls"}]
  end

  defp tls(_profile, _ordinal, _host, %Settings{tls_secret_name: nil}), do: nil

  defp tls(_profile, _ordinal, host, %Settings{tls_secret_name: secret}) do
    [%{"hosts" => [host], "secretName" => secret}]
  end

  # ingress-nginx reads these. Another controller would ignore them at best, so they are
  # written only for the class they mean something to. The cert-manager annotation is
  # added on top where an issuer is configured, because that one is read by cert-manager
  # rather than by the ingress controller and is not class-specific.
  defp ingress_annotations(settings) do
    settings
    |> controller_annotations()
    |> put_unless_nil("cert-manager.io/cluster-issuer", settings.cert_issuer)
    |> case do
      empty when map_size(empty) == 0 -> nil
      annotations -> annotations
    end
  end

  defp controller_annotations(%Settings{ingress_class_name: "nginx"}) do
    %{
      # The harness connection is a long-lived WebSocket, not a request: the proxy has to
      # sit on an idle socket for as long as a session sits between two tool calls.
      "nginx.ingress.kubernetes.io/proxy-read-timeout" => "3600",
      "nginx.ingress.kubernetes.io/proxy-send-timeout" => "3600",
      # Concurrent connections per client address. A pod holds a handful of sessions and
      # each session a handful of clients, so fifty is a whole office behind one NAT
      # address rather than a limit anybody reaches by using the thing.
      "nginx.ingress.kubernetes.io/limit-connections" => "50"
    }
  end

  defp controller_annotations(_settings), do: %{}

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
      "metadata" =>
        metadata(Names.workload(policy.namespace_prefix, profile.name), namespace, profile),
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
        "to" => [
          %{
            "namespaceSelector" => %{},
            "podSelector" => %{"matchLabels" => %{"k8s-app" => "kube-dns"}}
          }
        ],
        "ports" => [%{"protocol" => "UDP", "port" => 53}, %{"protocol" => "TCP", "port" => 53}]
      },
      # The plane's control listener, which is never exposed through ingress.
      %{
        "to" => [
          %{
            "namespaceSelector" => %{
              "matchLabels" => %{"kubernetes.io/metadata.name" => settings.plane_namespace}
            }
          }
        ],
        "ports" => [%{"protocol" => "TCP", "port" => settings.plane_control_port}]
      },
      # Everything outside the cluster: the LLM endpoint, the MCP servers, the git
      # hosts, and OpenBao and object storage when they are external. Narrowed to the
      # exact names by the Cilium policy where that is available.
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
    ] ++ in_cluster_rules(settings)
  end

  # And when they are *not* external. A worker fetches its session key from the key
  # manager and reads and writes sealed segments in object storage; a pod that could
  # reach neither could not activate a session at all. The rule above covers them only
  # while they are outside the cluster, which the chart's own defaults are not.
  defp in_cluster_rules(%Settings{} = settings) do
    [settings.bao_address, settings.object_store_endpoint]
    |> Enum.flat_map(&in_cluster_rule/1)
    |> Enum.uniq()
  end

  defp in_cluster_rule(nil), do: []

  defp in_cluster_rule(url) do
    # `URI.parse/1` fills the port in from the scheme, so by the time a host is in the
    # cluster the port is known.
    case URI.parse(url) do
      %URI{host: host, port: port} when is_binary(host) and is_integer(port) ->
        case cluster_namespace(host) do
          nil -> []
          namespace -> [namespace_rule(namespace, port)]
        end

      _other ->
        []
    end
  end

  # `openbao.troupe-system.svc` and `openbao.troupe-system.svc.cluster.local` both name
  # a Service in `troupe-system`. Anything else is a name this cluster does not serve,
  # and the ipBlock rule is what covers it.
  defp cluster_namespace(host) do
    case String.split(host, ".") do
      [_service, namespace, "svc" | _rest] -> namespace
      _other -> nil
    end
  end

  defp namespace_rule(namespace, port) do
    %{
      "to" => [
        %{
          "namespaceSelector" => %{"matchLabels" => %{"kubernetes.io/metadata.name" => namespace}}
        }
      ],
      "ports" => [%{"protocol" => "TCP", "port" => port}]
    }
  end

  defp cilium_network_policy(_namespace, _profile, %Settings{cilium_available: false}), do: []

  defp cilium_network_policy(namespace, profile, _settings) do
    patterns = Enum.map(Profile.egress_destinations(profile), &fqdn_selector/1)

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

  # `matchName` is an exact hostname and nothing else: a `*` in it is a literal star,
  # which no DNS answer ever carries, so a wildcard the policy admitted became a rule
  # that allowed nothing. `matchPattern` is what Cilium reads a wildcard with, and its
  # `*` stands for a run of hostname characters that does not include a dot — one label,
  # which is what `Troupe.Policy.matches?/2` and the admission CEL take `*.example.com`
  # to mean as well. The three agree, so a wildcard means the same thing wherever it is
  # checked.
  defp fqdn_selector(host) do
    if String.contains?(host, "*"),
      do: %{"matchPattern" => host},
      else: %{"matchName" => host}
  end

  defp pod_disruption_budget(namespace, profile, policy) do
    %{
      "apiVersion" => "policy/v1",
      "kind" => "PodDisruptionBudget",
      "metadata" =>
        metadata(Names.workload(policy.namespace_prefix, profile.name), namespace, profile),
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
        "volumeClaimTemplates" => [data_volume_template(profile)]
      }
    }
  end

  # A pod's own disk: the working copies of its live sessions, and nothing that has to
  # outlive them — the log is in object storage. Sized by the profile, 20Gi when it does
  # not say, and on the cluster's default storage class unless it names one. A volume
  # claim template is immutable once the StatefulSet exists, so changing either
  # afterwards is a new StatefulSet rather than a resize, and the apply that tries to
  # change it in place is refused by the API server.
  defp data_volume_template(profile) do
    spec =
      %{
        "accessModes" => ["ReadWriteOnce"],
        "resources" => %{"requests" => %{"storage" => profile.storage_size || "20Gi"}}
      }
      |> put_unless_nil("storageClassName", profile.storage_class)

    %{"metadata" => %{"name" => Names.data_volume()}, "spec" => spec}
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
      # Kubernetes injects a `<SERVICE>_PORT=tcp://ip:port` variable per Service for
      # Docker-links compatibility, and `troupe-plane-control` becomes
      # `TROUPE_PLANE_CONTROL_PORT` — the name a release reads a port number from. A pod
      # that inherited it would fail in its config provider before it logged anything.
      "enableServiceLinks" => false,
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
      # Two things a BEAM in a container gets wrong unless told.
      #
      # `+S` — the scheduler count comes from the host's CPU count, which in a container
      # is the node's. Only the downward API knows the pod's real limit.
      #
      # `+Q` — the port table is sized from `RLIMIT_NOFILE`, which containerd sets to
      # 1073741816. The table is then 1.5GB, allocated before a module is loaded, and the
      # pod is OOMKilled in a second with nothing in its log.
      %{
        "name" => "TROUPE_SCHEDULERS",
        "valueFrom" => %{
          "resourceFieldRef" => %{
            "containerName" => "worker",
            "resource" => "limits.cpu",
            "divisor" => "1"
          }
        }
      },
      %{
        "name" => "ERL_FLAGS",
        "value" => "+S $(TROUPE_SCHEDULERS):$(TROUPE_SCHEDULERS) +Q #{settings.max_ports}"
      },
      # Without this the release boots an empty supervision tree, which is what the same
      # image does on a laptop and must not do here.
      %{"name" => "TROUPE_WORKER_AUTOSTART", "value" => "true"},
      # And this is what makes the volume below a volume rather than a decoration. Without
      # it the worker writes to `$HOME/.local/state/troupe`, which is the container's own
      # ephemeral layer: the sealed-segment cache, the materialised bundles and every
      # restored workspace went there, and a pod restart threw all of it away while the
      # PersistentVolumeClaim this profile provisions sat empty. Nothing was *lost* —
      # sessions are in object storage and that is the point of sealing them — but every
      # restart paid to fetch and unpack everything again, and the volume's size class
      # decided nothing at all.
      %{"name" => "TROUPE_STATE_HOME", "value" => @state_dir},
      %{"name" => "TROUPE_PROFILE", "value" => profile.name},
      %{
        "name" => "TROUPE_NAMESPACE",
        "value" => Names.namespace(policy.namespace_prefix, profile.name)
      },
      %{"name" => "TROUPE_WORKERS_DOMAIN", "value" => policy.workers_domain},
      %{"name" => "TROUPE_WORKERS_SCHEME", "value" => settings.workers_scheme},
      %{
        "name" => "TROUPE_PLANE_CONTROL",
        "value" => "#{settings.plane_control_host}:#{settings.plane_control_port}"
      },
      %{"name" => "TROUPE_BAO_ADDR", "value" => settings.bao_address},
      %{"name" => "TROUPE_OBJECT_ENDPOINT", "value" => settings.object_store_endpoint},
      %{"name" => "TROUPE_OBJECT_BUCKET", "value" => settings.object_store_bucket},
      %{"name" => "TROUPE_OBJECT_REGION", "value" => settings.object_store_region},
      %{"name" => "TROUPE_SESSIONS_PER_POD", "value" => to_string(profile.sessions_per_pod)},
      %{"name" => "TROUPE_CONFIG_CHANNEL", "value" => profile.config_bundle_channel},
      %{
        "name" => "TROUPE_POD_ORDINAL",
        "valueFrom" => %{"fieldRef" => %{"fieldPath" => "metadata.name"}}
      }
    ]

    base ++
      workers_port_env(settings) ++
      allowed_origins_env(settings) ++
      object_store_env(settings) ++ llm_env(profile) ++ mcp_env(profile)
  end

  # Only when there is a list: a pod with the variable absent admits every origin, and
  # an empty string would say the same thing less clearly.
  defp allowed_origins_env(%Settings{worker_allowed_origins: []}), do: []

  defp allowed_origins_env(%Settings{worker_allowed_origins: origins}) do
    [%{"name" => "TROUPE_ALLOWED_ORIGINS", "value" => Enum.join(origins, ",")}]
  end

  # A pod that has an endpoint and a bucket but no credentials signs with `nil` and
  # crashes inside the signer, which is a long way from where the mistake was made.
  defp object_store_env(%Settings{object_store_secret_name: nil}), do: []

  defp object_store_env(%Settings{object_store_secret_name: name}) do
    [
      {"TROUPE_OBJECT_ACCESS_KEY_ID", "access-key-id"},
      {"TROUPE_OBJECT_SECRET_ACCESS_KEY", "secret-access-key"}
    ]
    |> Enum.map(fn {variable, key} ->
      %{
        "name" => variable,
        "valueFrom" => %{"secretKeyRef" => %{"name" => name, "key" => key, "optional" => true}}
      }
    end)
  end

  defp workers_port_env(%Settings{workers_port: nil}), do: []

  defp workers_port_env(%Settings{workers_port: port}) do
    [%{"name" => "TROUPE_WORKERS_PORT", "value" => to_string(port)}]
  end

  defp llm_env(%Profile{llm_endpoint: nil}), do: []

  defp llm_env(profile) do
    endpoint =
      [
        %{"name" => "TROUPE_BASE_URL", "value" => profile.llm_endpoint},
        %{"name" => "TROUPE_PROVIDER", "value" => profile.llm_provider}
      ] ++
        model_env("TROUPE_MODEL", profile.llm_model) ++
        model_env("TROUPE_SMALL_MODEL", profile.llm_small_model)

    key =
      if profile.llm_secret_name do
        [
          %{
            "name" => "TROUPE_API_KEY",
            "valueFrom" => %{
              "secretKeyRef" => %{
                "name" => profile.llm_secret_name,
                "key" => profile.llm_secret_key
              }
            }
          }
        ]
      else
        []
      end

    endpoint ++ key
  end

  defp model_env(_name, nil), do: []
  defp model_env(name, value), do: [%{"name" => name, "value" => value}]

  # The profile's MCP servers, as a pod learns them before any bundle arrives: the list
  # itself in `TROUPE_MCP_SERVERS`, and one variable per credential.
  #
  # The list is JSON in one variable rather than a variable per field because the worker
  # already has a reader for exactly this shape — `Troupe.MCP.Server.from_config/1`, the
  # same one the bundle push goes through — and a second flattening would be a second
  # contract. The map keys are few enough that Erlang keeps them sorted, so the encoding
  # is stable across reconciles; an env value that changed with map order would roll the
  # StatefulSet for nothing.
  #
  # Every credential is `optional: true`. Without it a missing Secret is a pod stuck in
  # `CreateContainerConfigError` with the reason three `kubectl` calls away; with it the
  # pod starts, the variable is simply absent, the worker sends no credential to that
  # server, and the profile's `SecretMissing` condition says what is wrong and where.
  defp mcp_env(%Profile{mcp_servers: []}), do: []

  defp mcp_env(%Profile{mcp_servers: servers}) do
    credentials =
      for %MCPServer{secret_name: secret} = server when is_binary(secret) <- servers do
        %{
          "name" => MCPServer.credential_env(server),
          "valueFrom" => %{
            "secretKeyRef" => %{"name" => secret, "key" => server.secret_key, "optional" => true}
          }
        }
      end

    configs = Enum.map(servers, &mcp_server_config/1)

    [%{"name" => "TROUPE_MCP_SERVERS", "value" => Jason.encode!(configs)} | credentials]
  end

  # `credential_ref` is only written when there is a Secret behind it: a reference to a
  # variable nothing sets would be a lie the worker then had to see through. The other
  # optional fields are left out when the spec is silent, so the worker's own defaults
  # apply rather than a `null` it has to be taught to ignore.
  defp mcp_server_config(%MCPServer{} = server) do
    %{
      "name" => server.name,
      "url" => server.url,
      "credential_ref" => if(server.secret_name, do: MCPServer.credential_env(server)),
      "header" => server.header,
      "timeout_ms" => server.timeout_ms
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # The projected token is the pod's enrolment credential, and the only one it has.
  defp volumes(profile) do
    # Two projected tokens rather than one automounted one. The default ServiceAccount
    # token is good at the API server and lasts as long as the pod; these are audience
    # -bound and short, so the one the plane accepts cannot open a session key and the one
    # the key manager accepts cannot enrol.
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
          },
          %{
            "serviceAccountToken" => %{
              "path" => "kms-token",
              "audience" => Names.kms_audience(),
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
            "claimName" => team_claim_name(team),
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
      %{"name" => Names.data_volume(), "mountPath" => @state_dir},
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
