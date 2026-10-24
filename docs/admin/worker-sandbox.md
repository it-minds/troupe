# The workers' sandbox on the nodes

Every command a session runs on a worker pod runs in bubblewrap, which builds its sandbox
from an unprivileged user namespace, and three things on the nodes decide whether it can
start there: the worker container's seccomp profile, its AppArmor profile, and a user
namespace of the pod's own. This page is step 2 of [installing](installing.md#2-crds-then-the-chart)
in full: what each needs, how to check a cluster before installing, and what bubblewrap's
refusals mean.

## The workers' seccomp profile

Every command a session runs on a pod runs in bubblewrap, which builds its sandbox from an
unprivileged user namespace. A container runtime's default seccomp profile refuses one, so
a worker under it refuses every command ("bubblewrap could not start one here (bwrap: No
permissions to create new namespace ...)"). `worker.seccomp` chooses the worker
container's profile, and the default needs nothing from you:

```yaml
worker:
  seccomp:
    type: Localhost                       # or RuntimeDefault, or Unconfined
    localhostProfile: troupe/worker.json  # under the kubelet's seccomp directory
    install:
      enabled: true                       # the DaemonSet below
      kubeletSeccompDir: /var/lib/kubelet/seccomp
```

- **`Localhost`**, the default, is the profile the chart ships: the runtime's default plus
  the calls bubblewrap makes its namespaces with
  ([security.md §3](security.md#3-a-worker-isolation-and-egress) says what it allows and
  why). The kubelet reads it from the node, so it must be on every node that runs workers.
  The `seccomp` container of the chart's DaemonSet `troupe-worker-profiles`, one per node,
  copies it there from a ConfigMap and waits, ready while the file is in place. It mounts
  that one host directory (`/var/lib/kubelet/seccomp/troupe`) and runs as root with every
  capability dropped, because the directory is root's, so `troupe-system` needs the
  `privileged` Pod Security level, which the chart labels it with while the DaemonSet runs
  (`podSecurity`). Where the kubelet runs with another `--root-dir`, set
  `kubeletSeccompDir` to `<root-dir>/seccomp`. A worker pod that reaches a node before the
  file waits in `CreateContainerError` ("cannot load seccomp profile") and starts once it
  is there: `kubectl -n troupe-system rollout status daemonset/troupe-worker-profiles`.
- **With the Security Profiles Operator**, or nodes built with the file, set
  `install.enabled: false` and point `localhostProfile` at where it is. For the operator,
  apply a `SeccompProfile` in `troupe-system` whose spec is the rules of
  `charts/troupe/files/worker-seccomp.json` (`defaultAction`, `architectures`, `syscalls`),
  and set `localhostProfile: operator/troupe-system/<its name>.json`.
- **`RuntimeDefault`** keeps the runtime's own profile: workers start and run no command.
- **`Unconfined`** is no filter at all, for a development cluster (`dev/kind/values.yaml`).
  The `baseline` and `restricted` Pod Security levels refuse it.

## The workers' AppArmor profile

Where a node enforces AppArmor, as Ubuntu's do, two things of AppArmor's stop bubblewrap:

- **The runtime's default AppArmor profile** (containerd's `cri-containerd.apparmor.d`)
  has `deny mount`, so bubblewrap stops at its first mount: "bwrap: Failed to make /
  slave: Permission denied".
- **Ubuntu's restriction on unprivileged user namespaces**
  (`kernel.apparmor_restrict_unprivileged_userns=1`, the default from Ubuntu 23.10, so on
  24.04 node pools). An unconfined process that makes a user namespace is moved into a
  profile with no capabilities, so a container with no AppArmor profile at all
  (`Unconfined`) gets one step further and stops at the namespace's uid map: "bwrap:
  setting up uid map: Permission denied".

`worker.appArmor` gives the worker container a profile of its own that answers both
without touching the node's sysctl: the runtime's default with bubblewrap's mounts and
`pivot_root` allowed, under which a worker is confined when it makes the namespace, so the
restriction does not apply ([security.md §3](security.md#3-a-worker-isolation-and-egress)
says what it allows and denies). The default needs nothing from you:

```yaml
worker:
  appArmor:
    enabled: true            # false on nodes without AppArmor
    profile: troupe-worker   # the name it is loaded under
    install:
      enabled: true          # the DaemonSet's `apparmor` container
```

- **Loaded on every node** by the `apparmor` container of `troupe-worker-profiles`, with
  `apparmor_parser --replace` from the operator's image; it then waits, ready while the
  kernel has the profile in enforce mode. Loading takes root in the node's user namespace
  with `MAC_ADMIN`, no AppArmor profile of its own, and the host's `/sys/kernel/security`,
  and the container has those and nothing else (every other capability dropped, a read-only
  root, no API token). A worker pod that reaches a node before the profile waits in
  `CreateContainerError` ("apparmor profile not found") and starts once it is loaded; it
  never runs without it.
- **A node without AppArmor**: the container loads nothing and says so in its log. The
  kubelet refuses a pod that asks for a profile there ("Cannot enforce AppArmor: AppArmor
  is not enabled on the host"), so a cluster whose nodes run no AppArmor sets
  `enabled: false`, and the worker container keeps the runtime's default.
- **With the Security Profiles Operator**, or nodes built with the profile
  (`charts/troupe/files/worker-apparmor`), set `install.enabled: false` and `profile` to the
  name it is loaded under.
- **Not the sysctl.** `kernel.apparmor_restrict_unprivileged_userns=0` would lift the
  restriction for every process on the node, and a managed node pool often cannot set it.
  The chart never sets it, and the worker container is never `Unconfined`.

## The workers' user namespaces

Bubblewrap also mounts a fresh `/proc` for the sandbox, and the kernel refuses that in a
user namespace while the runtime's masks hide part of the container's own (`/proc/kcore`
and others mounted over, `/proc/sys` read-only): "bwrap: Can't mount proc on /newroot/proc:
Operation not permitted". Kubernetes unmasks `/proc` only for a pod in a user namespace of
its own, so with `worker.userNamespaces: true`, the default, every worker pod gets
`hostUsers: false` and its worker container `procMount: Unmasked`, always together. Every
user in the container, root included, is then an unprivileged user on the node.

What the cluster needs for it:

| | |
| --- | --- |
| Kubernetes | 1.33 or later, where user namespaces are on by default |
| Container runtime | containerd 2.0 or later with runc 1.2 or later (CRI-O 1.25 or later with crun or runc should do; not tried) |
| Nodes | Linux 6.3 or later: the projected tokens and ConfigMaps are tmpfs, and idmapped tmpfs came in 6.3 |
| Storage | filesystems that take idmapped mounts. A block volume with ext4 or xfs does, and so do kind's and `local-path`'s directories. **NFS does not, and most RWX file storage is NFS**: a team volume there is expected to keep its pod in `ContainerCreating` or `CreateContainerError`, with the idmapped mount refused in the pod's events (not tried here) |
| Pod Security | nothing to do: `privileged` in the worker namespaces, since `baseline` and `restricted` refuse `procMount: Unmasked` even in a user namespace, and the operator labels each `troupe-w-<profile>` so (enforce, audit and warn), at every pass, a namespace made before it included. With `worker.userNamespaces: false` and a seccomp profile other than `Unconfined` the level is `restricted`. `podSecurity.labels: false` leaves the labels to you; a worker pod is then refused at creation where the cluster's default is higher, in a `FailedCreate` event on its StatefulSet |

A cluster that cannot have them sets `worker.userNamespaces: false`. Its workers start and
refuse every command, with bubblewrap's `/proc` sentence, until it can: a pod never runs a
command outside the sandbox.

**Check your cluster** before installing, with no secret and nothing of Troupe's but the
worker image. This makes a namespace, a volume on the storage class your profiles use, and
one pod as a worker pod would be, then runs a sandbox the way a worker does. Where the
nodes enforce AppArmor, run it once the chart's DaemonSet has loaded the profile
(`kubectl -n troupe-system rollout status daemonset/troupe-worker-profiles`), or install
with the check first and come back:

```bash
kubectl version | grep Server                    # 1.33 or later
kubectl get nodes -o custom-columns=NODE:.metadata.name,KERNEL:.status.nodeInfo.kernelVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion
kubectl create namespace troupe-check
kubectl label namespace troupe-check pod-security.kubernetes.io/enforce=privileged   # as the operator labels a worker namespace
kubectl apply -n troupe-check -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec:
  accessModes: [ReadWriteOnce]       # ReadWriteMany and the class your team volumes use, to check those
  storageClassName: standard         # the class your profiles name
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: worker-check}
spec:
  hostUsers: false
  securityContext: {runAsNonRoot: true, runAsUser: 1000, fsGroup: 1000}
  containers:
    - name: worker
      image: ghcr.io/it-minds/troupe-worker:X.Y.Z-beta   # the release you install
      command: ["sleep", "600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: ["ALL"]}
        seccompProfile: {type: Localhost, localhostProfile: troupe/worker.json}  # once the chart's DaemonSet has run; else Unconfined, for the check only
        appArmorProfile: {type: Localhost, localhostProfile: troupe-worker}       # where nodes enforce AppArmor, once the DaemonSet has loaded it; leave it out on nodes without
        procMount: Unmasked
      volumeMounts: [{name: data, mountPath: /var/lib/troupe}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: data}}]
YAML
kubectl -n troupe-check wait --for=condition=Ready pod/worker-check --timeout=120s
kubectl -n troupe-check exec worker-check -- sh -c '
  head -1 /proc/self/uid_map                     # not "0 0 4294967295"
  grep -c " /proc/" /proc/self/mountinfo         # 0: nothing masked
  touch /var/lib/troupe/ok && echo volume ok
  bwrap --unshare-pid --proc /proc --dev /dev --ro-bind /usr /usr --symlink usr/bin /bin \
    --symlink usr/lib /lib --symlink usr/lib64 /lib64 -- /bin/sh -c "cat /proc/1/comm"'   # bwrap
kubectl delete namespace troupe-check
```

A pod that never becomes ready says why in `kubectl -n troupe-check describe pod
worker-check`: `hostUsers` dropped or refused (Kubernetes or the runtime too old), an
idmapped mount refused (the storage), the seccomp profile missing from the node, the
AppArmor profile not loaded ("apparmor profile not found"), or AppArmor absent from the node
("Cannot enforce AppArmor": leave `appArmorProfile` out, and set
`worker.appArmor.enabled: false`).

What the last line, bubblewrap's, says when it does not print `bwrap`:

| bubblewrap says | what refused it | what fixes it |
| --- | --- | --- |
| `No permissions to create new namespace` | the seccomp profile: the runtime's default refuses a user namespace | `worker.seccomp.type: Localhost`, with the profile on the node |
| `Failed to make / slave: Permission denied` | AppArmor: the container runs under the runtime's default profile, which refuses every mount | `worker.appArmor.enabled: true`, with the profile loaded on the node, and `appArmorProfile` as above in the check |
| `setting up uid map: Permission denied` | AppArmor's restriction on unprivileged user namespaces (`kernel.apparmor_restrict_unprivileged_userns=1`): the container runs with no AppArmor profile (`Unconfined`), and an unconfined process that makes a user namespace is moved into a profile with no capabilities | the same: under the chart's profile the worker is confined, and the restriction does not apply. Never `Unconfined`, and the sysctl can stay as it is |
| `Can't mount proc on /newroot/proc: Operation not permitted` | the container's `/proc` is masked | `hostUsers: false` and `procMount: Unmasked` (`worker.userNamespaces: true`) |
