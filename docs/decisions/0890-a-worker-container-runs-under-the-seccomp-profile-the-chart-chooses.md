---
number: 890
title: "A worker container runs under the seccomp profile the chart chooses, by default the chart's own Localhost profile (the runtime's default plus the namespaces bubblewrap makes) put on every node by a DaemonSet that mounts that one directory, and a worker pod runs in a user namespace of its own with its /proc unmasked, so bubblewrap can mount the sandbox's own; kind uses Unconfined"
date: 2026-10-12
status: accepted
issue: 690
supersedes: [832]
paths:
  - apps/troupe_operator/lib/troupe/operator/settings.ex
  - apps/troupe_operator/lib/troupe/operator/resources.ex
  - apps/troupe_operator/test/troupe/operator/settings_test.exs
  - config/runtime.exs
  - charts/troupe/files/worker-seccomp.json
  - charts/troupe/templates/worker-seccomp.yaml
  - charts/troupe/templates/operator-deployment.yaml
  - charts/troupe/templates/_helpers.tpl
  - charts/troupe/values.yaml
  - dev/kind/values.yaml
  - scripts/kind-up
symbols:
  - Troupe.Operator.Settings.worker_seccomp/1
gist: "worker.seccomp Localhost (default + bwrap's namespaces, never net/cgroup/time); worker.userNamespaces: hostUsers false + procMount Unmasked, never apart"
---

Issue #690, found by the cluster suite's new bubblewrap test (#670, PR #686). The operator
gave every worker pod `seccompProfile: RuntimeDefault`, and the container runtime's
default profile refuses a process without `CAP_SYS_ADMIN` a new user namespace: `clone`
only without a namespace flag, and no `unshare`, `mount`, `umount2` or `pivot_root` at all.
Bubblewrap builds the sandbox every command on a pod runs in (Decision 832) from exactly
those, so a pod refused every command: in run 38294040077 the test's `shell.run` was
answered "this worker runs every command in a sandbox and bubblewrap could not start one
here (bwrap: No permissions to create new namespace, likely because the kernel does not
allow non-privileged user namespaces ...)". Decision 832 and D104 took this for a node
setting ("unprivileged user namespaces off ... needs its security profile changed"); the
node allowed them, and the pod's own profile was what refused. This replaces that part of
832 and nothing else: the refusal, the sentence and the log line stay as 832 has them.

- **A chart value chooses.** `worker.seccomp.type` is `Localhost`, `RuntimeDefault` or
  `Unconfined`, with `localhostProfile` the path under the kubelet's seccomp directory.
  The chart gives it to the operator (`TROUPE_WORKER_SECCOMP_TYPE`,
  `TROUPE_WORKER_SECCOMP_PROFILE`), which puts it on the worker container; the pod's own
  `securityContext` keeps `RuntimeDefault`, so anything else a pod ever runs beside the
  worker does not inherit the wider profile. It is the installation's, not a profile's,
  for the reason the rest of `Settings` is: a profile that could choose `Unconfined` would
  be one somebody would choose. The chart refuses another type, a `Localhost` without a
  path, and a path any part of which does not start with a letter or a digit (so `..`
  never takes the installer's mount out of the kubelet's directory); `config/runtime.exs`
  refuses the first two again when the operator starts.
- **`Localhost` by default, with the chart's profile.** `charts/troupe/files/worker-seccomp.json`
  is containerd 2.1's default profile as it renders for a container with every capability
  dropped (read from the OCI spec of such a container on kind, v1.34, containerd 2.1.3),
  for the x86 architectures the images are built for, with three changes and nothing
  else: `clone` is allowed with a user, mount, PID, IPC or UTS namespace flag where the
  default allows none (the rule's mask is `CLONE_NEWNET | CLONE_NEWCGROUP` where it was
  every namespace flag); `unshare` is allowed with the same flags (mask also
  `CLONE_NEWTIME`; bubblewrap calls it for its second user namespace, since `--dev` mounts
  a devpts); and `mount`, `umount2` and `pivot_root` are allowed, which a process without
  capabilities can use only inside a user namespace it made itself. A network, cgroup or
  time namespace is still refused, as is everything else the default refuses (`setns`,
  `bpf`, `keyctl`, `perf_event_open`, the io_uring calls and the new mount API among them;
  `clone3` still answers ENOSYS, so `clone` is what is used). No network namespace matters
  most: one a process owns would give it `CAP_NET_ADMIN` over netfilter there, where many
  user-namespace kernel exploits begin, and the sandbox does not unshare the network
  (Cilium's policy is the pod's).
- **Put on the nodes by a DaemonSet** (`templates/worker-seccomp.yaml`, on with
  `worker.seccomp.install.enabled` and `type: Localhost`). The profile is a ConfigMap; one
  pod per node copies it to `<kubeletSeccompDir>/<localhostProfile>` (written beside and
  renamed, so the kubelet never reads half), then sleeps, ready while the file matches.
  It mounts the profile's own directory from the host (`/var/lib/kubelet/seccomp/troupe`)
  and nothing else, runs as root because that directory is root's on a node, with every
  capability dropped, no privilege escalation, a read-only root, the runtime's default
  seccomp profile and no API token. It runs the operator's image, the release's own and
  already in its registry. A worker pod that lands on a node before the file is there
  fails `CreateContainerError` ("cannot load seccomp profile") and starts once it is.
- **The Security Profiles Operator** where a cluster runs one: `install.enabled: false`,
  the same rules as a `SeccompProfile`'s spec in `troupe-system`, and `localhostProfile`
  the path it installs it at, `operator/troupe-system/<name>.json`. Nodes built with the
  file are the same with no operator at all.
- **`Unconfined` on kind** (`dev/kind/values.yaml`). A cluster that is thrown away needs
  no node installer, and its worker namespaces are `privileged`. Never in production: it
  is no syscall filter at all.
- **`RuntimeDefault`** stays a choice: workers start, keep the runtime's filter, and
  refuse every command with 832's sentence. It is also what the operator uses when nothing
  sets the variable, so an operator without the chart fails closed, as 832 wants.
- **The profile is needed and not enough: a user namespace for each worker pod, with its
  `/proc` unmasked.** With the profile out of the way, bubblewrap made its namespaces and
  stopped at mounting the sandbox's own `/proc`: on CI's kind (v1.35, the runner's Ubuntu
  kernel) the bubblewrap test was answered "bubblewrap could not start one here (bwrap:
  Can't mount proc on /newroot/proc: Operation not permitted)" (runs 38307929071 and
  38311632983). The runtime masks paths under a container's `/proc` (`/proc/kcore` and
  others, mounted over, `/proc/sys` read-only), and the kernel refuses a new proc mount in
  a user namespace while the one it would reveal is not fully visible. Kubernetes unmasks
  a container's `/proc` (`procMount: Unmasked`) only for a pod in a user namespace of its
  own (`hostUsers: false`), where the container's root, and every other uid in it, is an
  unprivileged user on the node. `worker.userNamespaces` (default `true`) makes the
  operator write both, `hostUsers: false` on the worker pod and `procMount: Unmasked` on
  the worker container, from the one setting (`TROUPE_WORKER_USER_NAMESPACES`), so an
  unmasked `/proc` outside a user namespace is never rendered; the chart refuses a value
  that is not a boolean, since the string `"false"` reads as on. `false`, and an operator
  that is not told, keep today's pod: it starts, and refuses every command with 832's
  sentence. Chosen over a sandbox with no fresh `/proc` (an empty one breaks the tools a
  shell uses, and the pod's own would show the worker's processes and their environment
  to a command running as the same user) and over a privileged container.
- **What user namespaces need.** Kubernetes 1.33 or later (user namespaces on by default;
  `procMount` is kept, which it is on 1.34 with no feature gate set), containerd 2.0 or later
  with runc 1.2 or later, Linux 6.3 or later on the nodes (idmapped tmpfs, which the
  projected tokens and ConfigMaps are), and storage whose filesystems take idmapped mounts:
  a block volume with ext4 or xfs, and kind's local-path directories, do. NFS does not, and
  most RWX file storage is NFS: a team volume there is expected to keep its pod from
  starting, with the idmapped mount refused in the pod's events (not tried here). A cluster
  that cannot sets `worker.userNamespaces: false` and its workers run no command until it
  can.
- **Pod Security.** The operator labels no worker namespace, so they have the cluster's
  default level. `baseline` and `restricted` refuse `procMount: Unmasked` even in a user
  namespace (checked on 1.34), as they refuse `Unconfined`, so worker namespaces need
  `privileged`; `Localhost` and `RuntimeDefault` alone pass `restricted`, as the rest of
  the worker pod does. The chart cannot refuse the combination: the namespaces are made
  after it renders and take a level from the API server's admission configuration, which
  nothing can read through the API. Such a cluster refuses every worker pod at creation,
  in a `FailedCreate` event on the StatefulSet that names the field. The installer's
  DaemonSet mounts a host directory and runs as root, so its own namespace needs
  `privileged` too.
- **kind.** User namespaces work there with nothing enabled, once kind's createContainer
  hook can be reached: the runtime runs `/kind/bin/mount-product-files.sh` inside the pod's
  user namespace, as its root, which is nobody on the node, and the node image leaves
  `/kind` at 0644, so every user-namespaced pod failed "fork/exec
  /kind/bin/mount-product-files.sh: permission denied". `scripts/kind-up` opens `/kind`
  (0755; nothing in it is secret).
- **Upgrading** a plane that runs workers changes every profile's pod template: each
  reports `UpgradePending` and its pods are replaced as they empty (Decision 726). With
  `Localhost` the installer has to be ready first, which it is unless a node is missing,
  and the worker namespaces need `privileged` before the replacements are made, or the
  StatefulSet cannot create them.
- **Not chosen.** `Unconfined` in production: the sandbox would start, with no filter
  around it. `CAP_SYS_ADMIN` on the worker: it lets the default profile allow everything
  this does and far more, mounting in the pod's own namespace among it. A profile per
  profile: one pod's needs are every pod's. Docker's form of the default, with rules that
  hold only for some capabilities (`includes.caps`): a file cannot know a container's
  capabilities, the worker's are always none, and the form containerd renders itself, the
  OCI runtime spec's, is the one it was proven in.
- **Not done here.** AppArmor: where a node's runtime applies its default AppArmor profile,
  that profile has `deny mount`, which would refuse bubblewrap's mounts; neither kind
  cluster (CI's or Docker Desktop's) has AppArmor in its node, so it is unverified. arm64
  nodes: the images are built for amd64 alone. Docker Desktop's kind mounted a fresh
  `/proc` under the masked one, which CI's kernel refuses; why is not established, so a
  laptop's kind is no proof of the sandbox.
- **Proof.** Run 38294040077 (above) is the reproduction. On Docker Desktop's kind (v1.34,
  containerd 2.1.3), the worker image with the worker's security context: under
  `RuntimeDefault` `unshare -U` and bubblewrap with `Troupe.Sandbox`'s flags are refused;
  under the shipped profile, installed by the rendered DaemonSet, a user, mount and PID
  namespace are made, bubblewrap runs with those flags (`/proc/1/comm` is `bwrap`, no BEAM
  in sight) and git runs inside it, while a network, cgroup or time namespace is refused;
  under `Unconfined` all of it runs. A pod created before the installer failed
  `CreateContainerError` and started when the file arrived. The same pods with
  `hostUsers: false` and `procMount: Unmasked` run in a uid map of their own, with no mount
  over `/proc`, write their local-path volume as uid 1000 and read their projected token,
  and behave the same under each profile. In the operator suite each type and both
  user-namespace settings reach the worker pod, an unmasked `/proc` never renders without
  `hostUsers: false`, and a type the kubelet does not take is refused (`ResourcesTest`,
  `SettingsTest`); the chart job checks the chart's refusals. On CI's kind the cluster
  suite checks that the worker container wears the profile the installation chose and runs
  in a user namespace of its own with no mount over `/proc`, and the bubblewrap test runs a
  session's command in the sandbox.
