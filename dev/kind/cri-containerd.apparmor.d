# containerd's default AppArmor profile for a container, as containerd 2.x renders it from
# its template (contrib/apparmor/template.go) on a node whose daemon is unconfined.
#
# `scripts/kind-up` loads it into the host's kernel with the host's own parser before a kind
# node's containerd would, and containerd uses a profile of this name that is already
# loaded rather than compile its own. A kind node's parser is its Debian image's, older than
# the kernel of a current Ubuntu runner, and what it compiles for that kernel refuses every
# unix socket; the host's compiles it as an Ubuntu node's parser does.

#include <tunables/global>

profile cri-containerd.apparmor.d flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  network,
  capability,
  file,
  umount,
  # Host (privileged) processes may send signals to container processes.
  signal (receive) peer=unconfined,
  # runc may send signals to container processes.
  signal (receive) peer=runc,
  # crun may send signals to container processes.
  signal (receive) peer=crun,
  # Container processes may send signals amongst themselves.
  signal (send,receive) peer=cri-containerd.apparmor.d,

  deny @{PROC}/* w,   # deny write for all files directly in /proc (not in a subdir)
  # deny write to files not in /proc/<number>/** or /proc/sys/**
  deny @{PROC}/{[^1-9],[^1-9][^0-9],[^1-9s][^0-9y][^0-9s],[^1-9][^0-9][^0-9][^0-9/]*}/** w,
  deny @{PROC}/sys/[^k]** w,  # deny /proc/sys except /proc/sys/k* (effectively /proc/sys/kernel)
  deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,  # deny everything except shm* in /proc/sys/kernel/
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/kcore rwklx,

  deny mount,

  deny /sys/[^f]*/** wklx,
  deny /sys/f[^s]*/** wklx,
  deny /sys/fs/[^c]*/** wklx,
  deny /sys/fs/c[^g]*/** wklx,
  deny /sys/fs/cg[^r]*/** wklx,
  deny /sys/firmware/** rwklx,
  deny /sys/devices/virtual/powercap/** rwklx,
  deny /sys/kernel/security/** rwklx,

  # suppress ptrace denials when using 'docker ps' or using 'ps' inside a container
  ptrace (trace,read,tracedby,readby) peer=cri-containerd.apparmor.d,
}
