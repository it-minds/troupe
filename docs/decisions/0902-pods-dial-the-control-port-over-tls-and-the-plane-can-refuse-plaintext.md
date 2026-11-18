---
number: 902
title: "The operator copies the plane's control CA, its certificates alone, into every worker namespace on every pass and pods dial the control port with TLS against it; `plane.controlTls.requireTls` closes a plaintext connection after its first byte, off in 0.19 and on by default from 0.20; and the listener reads that byte and hands it to TLS through a transport of its own rather than putting it back with `unrecv`"
date: 2026-10-14
status: accepted
issue: 663
supersedes: [893]
paths:
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_plane/lib/troupe/plane/control/listener.ex
  - apps/troupe_plane/lib/troupe/plane/control/replay.ex
  - apps/troupe_plane/lib/troupe/plane/control/tls.ex
  - apps/troupe_worker/lib/troupe/worker/plane/link.ex
  - apps/troupe_operator/lib/troupe/operator/settings.ex
symbols:
  - Troupe.Plane.Control.Replay
  - Troupe.Plane.Control.TLS.required?/0
  - Troupe.Operator.Settings.with_plane_ca/1
gist: "Pods get the control CA (certs only) per namespace each pass and dial TLS; requireTls closes plaintext after byte 1 (on from 0.20); no unrecv"
---

This replaces 893's "Pods stay as they were" and its "one port, two ways in" mechanism;
the rest of 893 stands.

**The CA reaches the pods.** The chart mounts `ca.crt` alone out of the plane's
`plane.controlTls` Secret into the operator (`items:` lists the one key, so the kubelet
writes nothing else, the key least of all), optional as it is for the plane, and names it
in `TROUPE_PLANE_CONTROL_CA`. The operator reads the file on every pass
(`Settings.with_plane_ca/1`), keeps the certificates in it and writes only those out, and
puts them in each worker namespace as the ConfigMap `troupe-plane-ca`, one key, `ca.crt`. A
ConfigMap, not a Secret: a CA is not secret, the plane already hands it to anybody it
registers, and the operator needs no new right to read Secrets for it. The pod mounts the
ConfigMap's directory read-only at `/etc/troupe/plane-ca`, optionally, and is told
`TROUPE_PLANE_CA_PATH=/etc/troupe/plane-ca/ca.crt`; the link already dialled with TLS given
a CA, trusting that CA alone and checking the certificate against the name it dials, which
is the control Service's (`troupe-plane-control.<namespace>.svc`), and the certificate
carries it. No `TROUPE_PLANE_SERVER_NAME` is set.

Whether a pod is given the CA follows the installation (`plane.controlTls.enabled`), not
whether a pass could read the file, so a pass that could not changes no pod template; and
a pass that could not read it writes no ConfigMap and prunes none, so the namespaces keep
the CA they have. A pod made before the operator ever read one starts, its link logs that
the CA cannot be read, and it dials once the kubelet puts the file there. It never falls
back to plaintext: a link given a CA path dials with TLS or not at all.

**A renewed CA, without a restart.** cert-manager renews the chart's CA in place, keeping
its key (893). The kubelet updates the operator's mounted file; the operator's next pass,
within about thirty seconds, writes the new PEM into every namespace's ConfigMap, which
changes the ConfigMap and not the pod template, so no pod is replaced; the kubelet updates
each pod's mounted directory within its sync period; and the link reads the file again at
its next dial. A connection already open keeps the CA it was verified with until it
reconnects. The plane is not restarted at any point, and does not need to be: it reads its
own certificate at each handshake (893).

**The plane can refuse plaintext.** `plane.controlTls.requireTls` (chart) sets
`TROUPE_PLANE_CONTROL_REQUIRE_TLS` (`Troupe.Plane.Control.TLS.required?/0`). On, a
connection whose first byte is not a TLS handshake's is closed there, before anything after
that byte is read, with a warning naming the peer and saying what to do. The chart refuses
a string for it and refuses it without `enabled`, since a port taking TLS only with no
certificate enrols nobody; the listener's start line says "TLS only". Each enrolment's log
line now says whether it came "over TLS" or "in plaintext", which is how somebody sees,
before turning it on, whether any pod still dials without it.

**Off in 0.19, on by default from 0.20.** Worker pods are replaced only after a drain
(`OnDelete`, Decision 726), so after an upgrade to 0.19 a pod an 0.18 operator made can run
for as long as its sessions keep it busy, dialling in plaintext; refusing it would cut it
off from the plane until it is replaced. 0.19's operator gives every new pod template the
CA, so every pod rolls onto TLS as its drain completes. The default turns on in 0.20.0, by
which time every pod is one a 0.19 operator made; an installation can turn it on sooner
once its plane's log shows every enrolment over TLS. The kind cluster turns it on now.

**One byte read, and handed on.** The connection reads exactly one byte, passive, with the
handshake's ten-second limit (a client that connects and says nothing is closed). A `{` and
anything else not `22` starts the plaintext line buffer. A `22` goes to TLS through
`Troupe.Plane.Control.Replay`, which `:ssl.handshake/3` is given as its transport
(`cb_info`): `gen_tcp` and `:inet` in every call, except that the first time `:ssl`
activates the socket, the byte already read is sent to its own mailbox first, so it is
there before anything the socket delivers. The byte waits in a public ETS table keyed by
socket, owned by the listener and taken once. Everything it calls is documented, and it
works on either backend; `ControlTLSTest` runs the listener on both.

Not chosen: a separate TLS port, which would have broken either 0.18's machines, which
were told to dial TLS on this port, or 0.18's pods, which dial plaintext on it, and would
have changed the Service, the worker NetworkPolicy's egress rule and the operator's
settings. Peeking with `MSG_PEEK` through `:socket` on a duplicate of the descriptor was
tried: on the inet driver, closing the duplicate left the VM unable to deliver later data
on the original socket (a hang, after the second message, in a standalone probe); and
`:inet.getfd/1` on an `inet_backend: socket` socket fails in OTP 28. Putting the byte in
the new connection process's mailbox from `controlling_process/2`, before the handshake has
started, would leave it to whatever that process does with data in its first state; at
the first activation it is the handshake reading, as it reads everything after.
