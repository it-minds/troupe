---
number: 893
title: "The plane's control port serves TLS with a certificate cert-manager issues for the control Service through the chart, beside plaintext told apart by the first byte; a registered machine is given the certificate's CA at registration, pins it, and enrols over TLS alone, its secret refused in plaintext before it is looked at and never sent without TLS; a pod may still enrol in plaintext on the pod network"
date: 2026-10-13
status: accepted
issue: 663
paths:
  - apps/troupe_plane/lib/troupe/plane/control/tls.ex
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_plane/lib/troupe/plane/control/listener.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - clients/gui/apps/console/src/views/Hosts.tsx
  - apps/troupe_worker/lib/troupe/worker/plane/link.ex
  - config/runtime.exs
  - charts/troupe/templates/plane-control-tls.yaml
  - charts/troupe/templates/plane-deployment.yaml
  - charts/troupe/templates/_helpers.tpl
  - charts/troupe/values.yaml
  - dev/kind/values.yaml
  - scripts/remote-up
  - docs/admin/single-machine.md
  - apps/troupe_plane/test/support/control_tls_fixture.ex
  - apps/troupe_plane/test/troupe/plane/control_tls_test.exs
  - apps/troupe_worker/test/troupe/worker/machine_link_test.exs
  - apps/troupe_operator/test/e2e/enrolment_test.exs
symbols:
  - Troupe.Plane.Control.TLS
  - Troupe.Plane.Admin.host_register/3
  - Troupe.Plane.Admin.host_rotate/3
gist: "Control port: TLS from cert-manager's control-Service cert, plaintext by first byte; a machine pins the CA from registration, enrols over TLS only"
---

Issue #663, with the maintainer's decision of 2026-10-13: the control channel is TLS, with
a certificate cert-manager issues for the plane's control Service through the chart; a
machine receives the CA at registration and pins it; a plaintext connection from outside
the cluster is refused.

**What the tip did.** A machine registered through the `ssh` provisioner dialled the
control port over plain TCP and sent its host secret there in the clear: the worker's
`Troupe.Worker.Plane.Link` and the plane's `Troupe.Plane.Control.Listener` both used
`gen_tcp` and nothing else. The chart neither exposes the port nor admits it from outside
the worker namespaces, so for a pod it stays on the pod network; a machine outside the
cluster reaches it across whatever the installation routed it through, and
`single-machine.md` could only advise a tunnel. On the tip a plaintext `enrol` with a host
secret was accepted (`Troupe.Plane.ControlTLSTest`, six of its seven tests failing there).

**The certificate.** `plane.controlTls` in the chart, on by default. cert-manager issues a
`Certificate` for `troupe-plane-control` by every name a client in the cluster may use
(`troupe-plane-control`, `.<namespace>`, `.svc`, `.svc.cluster.local`) and the names and
addresses `dnsNames` and `ipAddresses` add for a machine's route, into
`troupe-plane-control-tls`. The issuer is one the installation names, an `Issuer` or a
`ClusterIssuer`, or with none a CA the chart makes for this alone: a self-signed issuer, a
CA certificate of ten years whose key is kept when it is renewed (`rotationPolicy: Never`),
and an issuer from it. A public ACME issuer is no use here: it does not issue for a
cluster-internal name, and its CA would vouch for anybody's host, which defeats pinning.
`certManager: false` mounts the Secret as somebody else put it there, which is what the
kind cluster does: `scripts/remote-up` makes a CA and a certificate with openssl, once, and
keeps them. The plane mounts the Secret at `/etc/troupe/control-tls`
(`TROUPE_PLANE_CONTROL_TLS_DIR`), optionally, so a plane whose certificate is not issued
yet still starts and enrols its pods; and it reads the files at each handshake
(`Troupe.Plane.Control.TLS`), because cert-manager renews the certificate in place and the
kubelet swaps the files under the running pod.

**One port, two ways in.** A TLS handshake opens with the byte `22` and a JSON-RPC line with
`{`, so a connection's first bytes say which it is: a handshake is put back on the socket
(`gen_tcp:unrecv/2`) and handed to `:ssl.handshake/3` with the certificate, anything else
is the first of a plaintext line. One port rather than a second for TLS keeps the
Service, the worker NetworkPolicy's egress rule and the operator's settings as they are,
and lets a pod move to TLS later on the same port. A TLS client to a plane with no
certificate is closed, since it asked for TLS and would not have sent its credential
without it.

**A machine enrols over TLS alone.** It is the worker outside the cluster, and its secret
lasts until somebody rotates it. On the plane, an `enrol` whose token is a host secret
(`twh_`) on a plaintext connection is refused before the secret is looked at:
`forbidden`, with a sentence saying to give the worker the CA and to rotate the secret,
which has crossed the network unencrypted, and a warning in the plane's log naming the peer.
Before the secret is looked at, so the refusal says nothing about whether it was valid, as
enrolment's one `unauthenticated` says nothing about which check refused
(`Troupe.Plane.Enrolment`). On the worker, the link reads its
credential before it dials: holding a host secret and no CA (`TROUPE_PLANE_CA_PATH`), it
does not dial at all and logs why, so the secret never reaches the wire; given a CA, it
dials with TLS, `verify_peer` against that CA and no other, the certificate checked against
the name it dials or `TROUPE_PLANE_SERVER_NAME` (a tunnel to `localhost`, an address the
certificate does not name). A certificate that CA did not sign, or for another name, stops
the dial at the handshake, before the credential is written, and is said once.
"Outside the cluster" is told by what a connection presents rather than by its address: an
address behind a load balancer, a node port or a tunnel says nothing, and a host secret is
what only a machine outside the cluster holds.

**The CA at registration.** `admin.host.register` and `admin.host.rotate` answer `ca`, the
PEM of `ca.crt`, beside the secret; the Provisioners screen shows it under the secret's
notice. It is not secret. A rotation answers it too, which is how a machine registered
before its plane had a certificate gets one, with a secret that has not crossed in
plaintext. A plane whose control port has no certificate refuses both (`unavailable`,
saying so): a secret it minted could never be used.

**Pods stay as they were, and may use TLS.** A pod dials the control Service on the pod
network, where the plane's NetworkPolicy admits the port from worker namespaces and the
operator alone, and its credential is a token projected for the plane's audience that
expires within the hour; it may still enrol in plaintext. Giving every pod the CA would
mean copying it out of the plane's namespace into each worker namespace, which the
operator does not do yet: a Secret cannot be mounted across namespaces, and the operator
would have to read this one. A pod given a CA (`TROUPE_PLANE_CA_PATH`) dials with TLS like a
machine, and the plane serves it, which `ControlTLSTest` shows; turning plaintext off for
pods is left for when the operator hands them the CA.

**Proof.** `Troupe.Plane.ControlTLSTest`, against a listener serving a certificate written
as cert-manager writes one (`Troupe.Plane.ControlTLSFixture`): a machine dials with TLS
against its pinned CA and enrols; its secret in plaintext is refused with the sentence and
never reaches the verifier, and the connection is closed; a client pinning another CA fails
the handshake; a TLS client to a plane with no certificate is closed; a pod enrols in
plaintext and over TLS; `TLS.ca/1` reads `ca.crt` and says what is missing.
`Troupe.ProvisionerTest`: registering and rotating answer the CA, and a plane with no
certificate registers nothing. `Troupe.Worker.MachineLinkTest`, the worker's link against
a real listener through a recording relay: with its CA it enrols over TLS and neither the
secret nor the word `enrol` is in the bytes that crossed; with no CA it never dials, and
nothing crosses; pinned to another CA, or checking another name, it stops at the
handshake and the verifier is never asked. The cluster suite (`mix troupe.e2e`): the
release's listener refuses a machine's secret in plaintext with the sentence, and over TLS
against the CA in `troupe-plane-control-tls` reads it and refuses it as `unauthenticated`.
`helm template` renders the chart's CA, a named `ClusterIssuer` with a machine's name and
address, the kind cluster's mounted Secret, and nothing with `enabled: false`, and refuses
a string for either flag, an empty `secretName` and an issuer kind that is neither.

**Not done.** The operator does not hand pods the CA, so pods enrol in plaintext, as they
did. A plane's log names the peer of a refused plaintext secret, not which machine it was:
looking the secret up to say so would be using it. A machine's CA is the chart's for ten
years; a renewed CA keeps its key, and a machine that pinned the first stays good until
that one's own end, ten years after it was made.
