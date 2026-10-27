# A worker: isolation and egress

Section 3 of [Security, for a reviewer](security.md): how a worker pod is held, what it may
reach, and what a session's agents on it may do. Each claim names the decision or the code
that makes it true.

- **The pod** (`Troupe.Operator.Resources`) runs as uid 1000, not root, every capability
  dropped and no privilege escalation. Its root filesystem is writable. No ServiceAccount
  token is mounted; two projected tokens are, one for enrolling with the plane and one for
  OpenBao.
- **The pod runs in a user namespace of its own** (`hostUsers: false`, `worker.userNamespaces`,
  Decision 890), so every user in it, root and uid 1000 included, is an unprivileged user
  on the node, mapped to a range no other pod has: a process that escaped the container
  would be nobody there. Its worker container's `/proc` is unmasked (`procMount: Unmasked`)
  so bubblewrap can mount the sandbox's own; Kubernetes allows that only inside a pod's own
  user namespace, and the operator writes the two together or neither, so what the masks
  hid (`/proc/kcore`, `/proc/sys`, ...) is visible only to a root with no privilege over
  the node. The Pod Security levels `baseline` and `restricted` refuse an unmasked `/proc`
  all the same, so worker namespaces are `privileged`, and the operator labels each so
  (`podSecurity`); with user namespaces off, the pod meets `restricted` and its namespace
  says that instead.
- **Every command runs in bubblewrap**, the shell's and every process Troupe starts there
  (git, ripgrep, a stdio MCP server), over the session's own directory. A pod that cannot
  start bubblewrap refuses the command with a sentence; it never runs one unconfined
  (Decision 832).
- **The worker container's seccomp profile lets bubblewrap make its namespaces, and no
  more** (`worker.seccomp`, Decision 890). Bubblewrap needs an unprivileged user namespace,
  and a container runtime's default profile refuses one, so by default the chart ships its
  own (`charts/troupe/files/worker-seccomp.json`) and a DaemonSet puts it on every node
  ([worker-sandbox.md](worker-sandbox.md#the-workers-seccomp-profile)). It is containerd's default
  profile for a container with no capabilities, with three changes:
  - `clone` and `unshare` may make a user, mount, PID, IPC or UTS namespace, the ones the
    sandbox is made of;
  - `mount`, `umount2` and `pivot_root` are allowed, which a process with no capabilities
    can use only inside a user namespace it made, where bubblewrap builds the sandbox's
    root;
  - nothing else. A network, cgroup or time namespace is still refused, so a command never
    owns a network namespace and the netfilter it would bring (`CAP_NET_ADMIN` there is
    where many kernel exploits through user namespaces start), and `setns`, `bpf`,
    `keyctl`, `perf_event_open`, io_uring and the new mount API stay refused as in the
    default.

  What this adds is the kernel's user-namespace code, reachable from a command a session
  runs. That is the price of a sandbox built without privileges, and less than the
  alternatives: `CAP_SYS_ADMIN` would allow all of this and mounting in the pod's own
  namespace besides, and `Unconfined`, which the development cluster uses, removes the
  filter. Only the worker container has this profile; the pod keeps the runtime's default.
  `RuntimeDefault` remains a choice, under which no command runs on a pod.
- **The worker container's AppArmor profile lets bubblewrap mount the sandbox, and no
  more** (`worker.appArmor`, Decision 898). Where a node enforces AppArmor, the runtime's
  default profile refuses every mount, and Ubuntu's restriction on unprivileged user
  namespaces (`kernel.apparmor_restrict_unprivileged_userns=1`) refuses an unconfined
  process the uid map of one it makes. The chart ships its own
  (`charts/troupe/files/worker-apparmor`), and a DaemonSet loads it on every node
  ([worker-sandbox.md](worker-sandbox.md#the-workers-apparmor-profile)). It is containerd's default
  profile with these changes:
  - `mount` and `pivot_root` are allowed, where the default denies every mount. As with
    seccomp, a process with no capabilities can mount only inside a user and mount
    namespace it made itself, so these reach the sandbox's mounts, never the pod's;
  - a worker is confined by it, so the kernel's restriction on unprivileged user
    namespaces, which applies to unconfined processes, does not move it into a profile with
    no capabilities. The profile is written for the AppArmor 3.0 policy ABI, which the
    parser that loads it speaks and which does not mediate user namespaces, so a worker may
    make one. The node's sysctl is left as it is, so every other process keeps the
    restriction;
  - denied beyond the default: mounting sysfs, cgroup and cgroup2, mqueue, fuse, overlay,
    bpf, ramfs and binder filesystems even inside the sandbox; the capabilities that mean
    something only in the node's own namespace (`mac_admin`, `mac_override`, `sys_module`,
    `sys_rawio`, `sys_boot`, `sys_time`, `syslog`, `audit_control`); and raw IP and packet
    sockets (netlink's stay, which listing the network interfaces needs). The default's denials stay: no writes to the kernel's files in `/proc` or to
    sysfs outside cgroups, nothing of `/proc/kcore`, `/proc/sysrq-trigger`, firmware or
    `/sys/kernel/security`.

  The loader is the one new privilege: a container per node, root in the node's user
  namespace with `MAC_ADMIN` alone, unconfined by AppArmor (the default profile would refuse
  it `/sys/kernel/security`, the only part of the host it mounts). The worker container is
  never `Unconfined`, and on a node without AppArmor the kubelet refuses a worker pod that
  asks for the profile rather than run it without.
- **Network.** Each profile's namespace has a NetworkPolicy: ingress only from the
  namespace labelled `troupe.dev/ingress=true`, egress to DNS, the plane, OpenBao, object
  storage, the model, the MCP servers and the git hosts. **With Cilium** the profile's
  allowlist is enforced on the wire by name, and Decision 856's addresses are denied
  whatever a name resolves to. **Without Cilium** a worker reaches any public address on 443
  and 80 (link-local, the private ranges and `100.64.0.0/10` left out), and the allowlist is
  checked only when a profile is admitted
  ([profiles-and-policy.md](profiles-and-policy.md#4-troupepolicy)).
- **Admission.** A cluster admin's `TroupePolicy` caps images, replicas, resources, egress
  and storage, enforced by a `ValidatingAdmissionPolicy` and again by the operator. The
  plane cannot write it and has no verb on Secrets, so a compromised plane can only submit
  profiles that must still pass both ([roles-and-permissions.md §7](roles-and-permissions.md#7-kubernetes-rbac-the-chart-grants)).
  An egress entry is an exact name or a one-label wildcard (`*.example.com`), in the
  policy and in a profile alike; a bare `*` or any other star is refused, and a policy
  holding one admits no profile, so no rule for every name is ever written (Decision 883).
- **Reaching a pod.** Each pod has an Ingress of its own and is internet-facing by design.
  A client needs a session token the plane signed for that pod, and the pod checks the
  plane's access list at every command, so a role the plane narrows or revokes holds at the
  person's next command (Decision 859). A browser page gets a socket only from an origin
  the deployment lists (`operator.workerAllowedOrigins`, and the plane's own where the
  chart serves the GUI); with none listed, no page does. The desktop app and `troupe` are
  not pages and need no entry (Decision 884).
- **The control channel.** A worker dials the plane's control port, never the other way
  round. A pod enrols with its projected token, bound to the plane's audience and good for
  an hour, on the pod network, where the plane's NetworkPolicy admits the port from worker
  namespaces alone, over TLS against the CA the operator gives its namespace; the plane
  closes a plaintext connection unless `plane.controlTls.requireTls` is off (Decision 906).
  A pod made before its namespace had the CA, which dials in plaintext and so can neither
  enrol nor be drained, is replaced by the operator once TLS is required, and puts its
  sessions to sleep as it stops.
  A machine registered outside the cluster ([single-machine.md](single-machine.md)) enrols
  with a secret that lasts until rotated, so over TLS only: it is given the control
  certificate's CA at registration and trusts no other, does not dial without it, and a
  secret sent in plaintext anyway is refused unread, with a sentence saying to rotate it
  (Decision 893).
- **GitHub: a token the session never holds, its own branch, never a merge.** A session
  that names a repository is cloned with an installation token for that one repository,
  `contents: read`, for an hour, which the pod's own git takes through a credential helper;
  `.git/config`, the agent's `shell` and every tool's output have no way to it. On a
  profile that grants it, four tools the pod runs outside the sandbox push the session's
  one `troupe/*` branch as a commit the App's bot signs, never with force, open a draft
  pull request and read its CI; no tool merges or approves, and three red CI rounds close
  its pushes. A push goes only to a repository the team lists, private unless the profile
  allows public ones, and never carries `.env`, a key file, a denied path or a copy of a
  mounted secret; tokens are revoked when the session goes dormant. Every token, push and
  stop is an audit entry (Decisions 885, 891 and 911; [github-runs.md](github-runs.md#the-fix-loop),
  [§9](github.md#9-how-far-a-run-may-go)).
- **One OpenBao role for every profile, by default.** Every worker logs in as
  `troupe-worker`. `bao.workerRolePerProfile` gives each profile a role of its own, so one
  profile's pods cannot read another's session keys
  ([roles-and-permissions.md §8](roles-and-permissions.md#8-openbao-policies)).

[What a worker can reach](profiles-and-policy.md#what-a-worker-can-reach) has the same in
one list, with links to where each part is set.
