---
number: 898
title: "A worker container runs under the chart's own Localhost AppArmor profile, containerd's default with bubblewrap's mounts and pivot_root allowed and more denied, loaded into every node's kernel by a container of the workers' profile DaemonSet with MAC_ADMIN alone and the host's securityfs; a worker under it is confined when it makes the sandbox's user namespace, so Ubuntu's restriction on unprivileged ones does not apply and the node's sysctl is left alone"
date: 2026-10-13
status: accepted
issue: 705
paths:
  - charts/troupe/files/worker-apparmor
  - charts/troupe/templates/worker-profiles.yaml
  - charts/troupe/templates/operator-deployment.yaml
  - charts/troupe/templates/_helpers.tpl
  - charts/troupe/values.yaml
  - apps/troupe_operator/lib/troupe/operator/settings.ex
  - apps/troupe_operator/lib/troupe/operator/resources.ex
  - apps/troupe_operator/test/troupe/operator/settings_test.exs
  - apps/troupe_operator/test/e2e/isolation_test.exs
  - config/runtime.exs
  - docker/Dockerfile
  - dev/kind/values.yaml
  - scripts/kind-up
  - scripts/remote-up
  - .github/workflows/cluster.yml
  - docs/admin/installing.md
symbols:
  - Troupe.Operator.Settings.worker_apparmor/1
gist: "worker.appArmor: Localhost troupe-worker (containerd default + mount/pivot_root, abi 3.0, more denials), loaded by the DaemonSet's MAC_ADMIN container; never Unconfined; sysctl untouched"
---

Issue #705, found by the cluster check in `docs/admin/installing.md` on a production cluster
of Ubuntu 24.04.4 nodes (kernel 6.8, containerd 2.3.4). Decision 890 gave the worker
container a seccomp profile and a user namespace and left AppArmor unverified, since
neither kind cluster it was proven on applied AppArmor. On those nodes it stopped
bubblewrap twice. Under containerd's default AppArmor profile, `cri-containerd.apparmor.d`,
which has `deny mount`, bubblewrap made its user namespace and its uid map and stopped at
its first mount: "bwrap: Failed to make / slave: Permission denied". With the container
`Unconfined` it got one step less far: Ubuntu 23.10 and later set
`kernel.apparmor_restrict_unprivileged_userns=1`, under which an unconfined process that
makes a user namespace is moved into a profile with no capabilities, so the namespace's uid
map could not be written: "bwrap: setting up uid map: Permission denied". CI's cluster job
had lifted that sysctl on its runner (#686), which is why it never saw the second.

- **A chart value, on by default.** `worker.appArmor` (`enabled`, `profile`, default
  `troupe-worker`, `install`) reaches the operator as `TROUPE_WORKER_APPARMOR_PROFILE`, a
  name and nothing else. With it the operator writes `appArmorProfile: {type: Localhost,
  localhostProfile: <name>}` on the worker container, the field Kubernetes 1.30 made GA,
  which user namespaces (1.33) already require; the pod's own security context keeps the
  runtime's default, as with seccomp. Unset, as for an operator without the chart, the
  field is left out and the container keeps the runtime's default, as before. No value
  makes the worker container `Unconfined`: the setting holds a name, and the chart and
  `config/runtime.exs` refuse one that is not letters, digits, `.`, `_` and `-`, and the
  chart a non-boolean `enabled`. `hostUsers: false` and `procMount: Unmasked` are unchanged.
- **The profile** (`charts/troupe/files/worker-apparmor`) is containerd's default, line for
  line where it applies (network, capabilities as the kernel grants them, files, unmount,
  signals from the runtime and among its own, ptrace among its own, the `/proc` and `/sys`
  denials), with `deny mount` replaced by `mount` and `pivot_root`: bubblewrap makes `/` a
  slave, puts a tmpfs where it builds the root, binds and remounts the read-only roots and
  the session's mounts, mounts a proc, a `/dev` with a devpts and a `/tmp`, and pivots.
  The kernel lets a process without capabilities mount only inside a user and mount
  namespace it made, so these reach the sandbox's mounts and never the pod's. It adds
  denials, so what a worker never needs is written down: sysfs, cgroup, cgroup2, mqueue,
  fuse, overlay, bpf, ramfs and binder mounts even inside the sandbox; the capabilities
  that mean something only in the node's own namespace; raw and packet sockets.
- **The user namespace.** A worker under the profile is confined, and the restriction
  applies only to an unconfined task; for a confined one the kernel asks its profile. The
  profile is written for the AppArmor 3.0 policy ABI (`abi <abi/3.0>,`), because the
  parser that loads it is Debian 12's, AppArmor 3.0.8, which is what the release images are
  built on and which has no `userns` rule. A policy compiled to that ABI does not mediate
  user namespaces, and the kernel lets a task under a profile that does not mediate them
  make one. That is the mechanism the production evidence already showed: under
  containerd's default profile, also confined and also not mediating them on those nodes,
  bubblewrap got past the uid map and stopped only at the mount. When the images move to
  Debian 13 (AppArmor 4.1), the profile moves to `abi <abi/4.0>,` with an explicit `userns,`
  rule; until then the comment at its head says so.
- **The node's sysctl is left alone.** Setting `kernel.apparmor_restrict_unprivileged_userns`
  to 0 would lift the restriction for every process on the node, needs a privileged
  DaemonSet writing the node's sysctls or the node pool's own settings, and managed pools
  often offer neither. The profile needs neither. CI's cluster job stops lifting it.
- **Loaded by the workers' profile DaemonSet.** The DaemonSet that put the seccomp profile
  on the nodes is now `troupe-worker-profiles`, rendered when either profile is to be
  installed, with a container for each, so neither is given what the other needs. The
  `apparmor` container runs `apparmor_parser --replace --skip-cache` on the profile from a
  ConfigMap, then waits, ready while `/sys/kernel/security/apparmor/profiles` lists it in
  enforce mode. Loading a profile takes root in the node's user namespace with
  `CAP_MAC_ADMIN`, a task the kernel lets manage policy, which containerd's default profile
  is not (it denies `/sys/kernel/security`), and the host's securityfs; the container has
  exactly those: `MAC_ADMIN` added to an empty capability set, `appArmorProfile:
  Unconfined` on that container alone, the host's `/sys/kernel/security` mounted, a
  read-only root, no privilege escalation, the runtime's default seccomp profile and no
  API token. Not `privileged: true`, and not the host's `/etc/apparmor.d`: a loaded profile
  lasts until the node reboots, when the DaemonSet's pod starts again and loads it again.
  The parser is in the operator's image (Debian's `apparmor` package, in that image alone),
  the release's own and already pulled by the DaemonSet. `troupe-system` needs the
  `privileged` Pod Security level for it, as it already did.
- **A node without AppArmor.** The container loads nothing, says so in its log and is
  ready. The worker pod is not changed per node: a pod spec is one for every node, and
  choosing per node would need node labels the installer would have to write with API
  rights. So the operator asks whenever the value says so, and that is the safer choice:
  on a node without AppArmor the kubelet refuses a pod that asks for a profile ("Cannot
  enforce AppArmor: AppArmor is not enabled on the host"), visibly, and never runs it
  without one. A cluster whose nodes have none sets `worker.appArmor.enabled: false`.
- **A worker pod before the profile** fails `CreateContainerError` ("apparmor profile not
  found") and the kubelet retries it until the DaemonSet has loaded it, as with the seccomp
  profile. It waits; it never runs unconfined.
- **The Security Profiles Operator**, or nodes built with the profile: `install.enabled:
  false` and `profile` the name it is loaded under.
- **kind.** `dev/kind/values.yaml` leaves it off, since Docker Desktop's kernel runs no
  AppArmor and its kubelet would refuse the pods. Where the host's kernel runs AppArmor
  (CI's Ubuntu runner, an Ubuntu laptop), `scripts/kind-up` gives each node
  `apparmor_parser` and securityfs and restarts containerd, which takes AppArmor for absent
  without the parser ("apparmor is not supported"); every other pod there then runs under
  containerd's default profile, as on an Ubuntu node. `scripts/remote-up` turns the profile
  on where a node's runtime can apply it.
- **Upgrading** renames the DaemonSet (Helm removes `troupe-worker-seccomp` and makes
  `troupe-worker-profiles`) and adds the loader's privilege. The setting changes every
  profile's pod template: each reports `UpgradePending` and its pods are replaced as they
  empty (Decision 726), under the profile.
- **Not chosen.** `Unconfined` for the worker container: the issue's first option; no
  AppArmor at all, and on these nodes still refused its uid map. The sysctl, behind a
  value: node-wide, and the maintainer's call (2026-10-13) was to leave it. A loader image
  of its own, or the host's parser through a mount of the host's root: an image more to
  build and publish, or the whole node's filesystem for one file.
- **Proof.** In the operator suite the profile reaches the worker container, nothing else
  about its confinement changes and the pod keeps the runtime's default, and none is
  written without a name (`ResourcesTest`); a name the kubelet would not take stops the
  operator (`SettingsTest`); the chart job checks the chart's refusals. On CI's cluster
  job, on an Ubuntu 24.04 runner left with AppArmor enforced and
  `kernel.apparmor_restrict_unprivileged_userns=1`, the step "Bubblewrap on a worker needs
  the chart's AppArmor profile here" runs the worker image with the worker container's
  security context and bubblewrap's flags three times: under containerd's default profile
  and unconfined it is refused, and under the chart's profile, loaded by the DaemonSet, it
  runs; then the cluster suite checks the worker container wears and runs under the profile
  and runs a session's command in the sandbox.
