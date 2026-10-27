# A worker on a machine you already have

The rest of this product assumes a cluster. This page is for the case that does not: one
laptop, or one build box, running a worker that a plane places sessions on.

The cluster is the expensive half: a developer who wants Troupe's sessions, bundles and log
on the machine in front of them should not have to stand up Kubernetes first, and a team
whose CI runs on one box should be able to give that box to a profile and stop there.

> **This is deliberate friction, and it is not a way around the policy.** A machine is not
> a cluster, and the guarantees Kubernetes provides are not there. Everything below says
> which, where it matters.

---

## What you give up, named one at a time

A pod gets four things from the cluster, enforced whether or not the plane is running. A
machine gets none of them:

| | on Kubernetes | on a machine |
| --- | --- | --- |
| admission policy | `ValidatingAdmissionPolicy` refuses a profile that breaks the rules | **not given** |
| network policy | a worker reaches only what the policy allows | **not given** |
| egress by hostname | Cilium FQDN rules, where available | **not given** |
| disruption budget | a `PodDisruptionBudget` keeps capacity during a drain | **not given** |

The console's **Provisioners** screen shows this table for your deployment, per substrate
and again per profile. "Unenforced" is not a useful thing to tell somebody deciding whether
their team's work may run on somebody's build box; four names are.

Because of that, a team may be granted a profile on a machine **only** after a platform
admin has allowed it for that team by name. The grant is refused until then, with the
missing guarantees quoted:

```
forbidden — this substrate does not provide admission_policy, network_policy,
fqdn_egress, disruption_budget; a platform admin must allow unenforced workers for this
team first
```

---

## 1. A profile whose workers are machines

Create the profile with `admin.profile.put`, on `/rpc` or `/mcp`, with `provisioner: "ssh"`;
the console's profile editor has no field for it. The name is the profile's; the `ssh` is
what says its workers are registered rather than reconciled.

Nothing about the rest of the profile changes. The image, the size class, the bundle
channel and the egress lists all mean what they mean anywhere else — what changes is who
makes the worker exist.

---

## 2. Register the machine

On **Provisioners**, under *Machines registered to &lt;profile&gt;*, give the machine a name
and register it. You get a secret, **once**, and under it the CA the machine will pin:

```
build-box registered — secret, shown once: twh_9f3c…
```

Nothing shows it again: the plane keeps a hash, as it does a service principal's. Lose it
and you rotate.

The CA is no secret. It signed the certificate the plane's control port serves, which
cert-manager issues for the control Service through the chart (`plane.controlTls`), and
`admin.host.register` and `admin.host.rotate` answer it as `ca`. The machine dials the plane
with TLS, trusts that CA and nothing else for it, and never sends its secret any other way.
A plane whose control port has no certificate registers no machine, and says so.

The address field is for you. **Nothing here connects to it** — the worker dials the plane,
never the other way round, which is what makes a machine behind NAT work at all and why
this provisioner creates nothing and holds no key.

---

## 3. Install the worker on it

The worker is the same release the chart deploys, run as a process rather than as a pod.
No release asset carries it: take it from the `ghcr.io/it-minds/troupe-worker` image, or
build it from source. Like a pod, it runs every command in bubblewrap, so the machine needs
bubblewrap and unprivileged user namespaces, or it refuses every command (Decision 832).

```bash
install -d -m 700 /etc/troupe
printf '%s' 'twh_9f3c…' > /etc/troupe/token && chmod 600 /etc/troupe/token
cat > /etc/troupe/plane-ca.pem    # paste the CA the registration showed, then Ctrl-D

TROUPE_WORKER_AUTOSTART=true \
TROUPE_PLANE_CONTROL=control.example.com:4001 \
TROUPE_PLANE_CA_PATH=/etc/troupe/plane-ca.pem \
TROUPE_TOKEN_PATH=/etc/troupe/token \
TROUPE_PROFILE=laptops \
TROUPE_OBJECT_ENDPOINT=https://s3.example.com TROUPE_OBJECT_ACCESS_KEY_ID=… TROUPE_OBJECT_SECRET_ACCESS_KEY=… \
TROUPE_BAO_ADDR=https://bao.example.com TROUPE_BAO_TOKEN=… \
  bin/troupe_worker start
```

A pod logs in to OpenBao with its projected token, which a machine does not have, so the
machine needs `TROUPE_BAO_TOKEN`, and the object store's credentials as a pod's
`troupe-object-store` Secret gives them ([configuration.md A.3](configuration.md#a3-worker-troupe_worker)).

**The control channel is TLS, and the machine checks whom it is talking to.** With
`TROUPE_PLANE_CA_PATH` the worker dials with TLS and accepts only a certificate that CA
signed, for the name it dials. Without it, a worker holding a machine's secret does not
dial and logs why, and a plane sent a machine's secret in plaintext refuses it before
looking at it and logs that it must be rotated
([a worker's isolation and egress](security-worker.md)).

The chart does not expose the control port outside the cluster: no Ingress, and its
NetworkPolicy admits the port only from worker namespaces and the operator. Reaching
`4001` from a machine takes a route of your own (a `LoadBalancer` Service, a node port) and
a policy that admits it, and the name or address the machine dials goes into the
certificate: `plane.controlTls.dnsNames` or `.ipAddresses`. Where it dials through
something else, an SSH tunnel to `localhost` say, `TROUPE_PLANE_SERVER_NAME` names what the
certificate is checked against instead, such as `troupe-plane-control.troupe-system.svc`.
A tunnel is no longer needed for the secret's sake, only where you would rather not open
the port to the machine's network at all.

`TROUPE_HOST_SECRET` takes the secret directly, for a one-liner. The file is better, and
shown first: an environment variable is readable in `/proc` and in `ps` output by anybody
on the machine. A pod uses neither: its token is projected at a fixed path and rotated in
place.

It enrols over the control channel as a pod does. Enrolment proves the machine is *this*
machine of *that* profile (a pod proves it with a TokenReview against its namespace, a
machine with the secret you minted), and every way of failing is the same single
`unauthenticated`, so a caller learns nothing from which.

The console shows it as **registered, never seen** until it arrives: a machine nobody has
installed the worker on yet is a different job from one that is switched off.

---

## 4. Allow a team on it, deliberately

On **Teams**, with the team open, tick **may run where nothing is enforced**
(`allow_unenforced_workers`). Only a platform admin sees or sets it: a flag a team could
give itself is no decision about that team, so a team admin's attempt is refused rather
than dropped. Then grant the profile; it is refused before this and accepted after, both
in the audit trail.

Taking the permission back while the grant stands is refused too, naming the profiles,
since it would make "granted, and not allowed" by the back door. Revoke first, then clear
it.

---

## What does not change, and is the whole point

* **The session log, the seal format, the object layout and the key paths are
  byte-identical.** A session sealed on a machine restores on a pod and the other way
  round.
* **Placement does not know there is more than one kind of worker.** Capacity, health,
  drain state and the disk watermark are reported the same way, over the same channel.
* **Draining is the same sequence**: stop placing, let running turns finish, get everything
  into object storage. What differs is what happens to the machine afterwards, and for a
  machine the answer is nothing at all — it is yours.

---

## What a machine cannot do

**Scale.** A profile asking for four workers on a substrate with two registered machines is
not a transient condition the next tick fixes; it is somebody who has to install the worker
on two more. The shortfall is reported rather than retried, and the fleet is treated as as
large as it can be — which keeps `session.create` on the waiting path rather than the
refusing one.

**Be reached by the plane.** Every operation is the worker dialling out. There is no
`ensure` that creates a machine, because there is no machine to create.
