> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).

# Deployment

How a built bundle reaches people: the Helm chart, the deploy script, the base-path
contract, and what is recorded about the one live deployment. Operator-facing detail
(every value, every runtime behaviour) is in [../admin/configuration.md](../admin/configuration.md)
and [../admin/operations.md](../admin/operations.md).

## The shape

One image, one Deployment, one Service, one Ingress. The container takes no environment
variables and holds no secret (`charts/troupe-gui/values.yaml:1-3`; the Deployment
template has no `env:` block, `templates/deployment.yaml:27-51`). Everything a user's
browser then does goes from the browser to the plane and to a worker pod — the GUI's
pods are never in that path (`Dockerfile:3-6`).

## The Helm chart

`charts/troupe-gui/`, `apiVersion: v2`, chart version and `appVersion` both `0.1.0`
(`Chart.yaml:1-6`). Templates:

| Template | Renders | Notes |
|---|---|---|
| `deployment.yaml` | `Deployment` with `replicas` (`:7`), pod security context uid/gid 101, `RuntimeDefault` seccomp (`:22-26`), image `repository:tag` with the tag defaulting to `appVersion` (`:29`), port 8080 named `http` (`:31-33`), read-only root filesystem, no privilege escalation, all capabilities dropped (`:34-37`), readiness and liveness on `/healthz` (`:40-47`), `emptyDir`s for `/var/cache/nginx` and `/tmp` (`:49-54`) | Optional `imagePullSecrets`, `podAnnotations`, `nodeSelector`, `tolerations`, `affinity` (`:13-19`, `:55-63`) |
| `service.yaml` | `ClusterIP`, port 80 → `http` (`:7-12`) | |
| `ingress.yaml` | Only when `ingress.enabled`; `ingress.host` is required (`:1-5`). With a base path: `rewrite-target: /$2` and path `<base>(/\|$)(.*)` `ImplementationSpecific` (`:12-19`, `:37-42`); at `/`: path `/` `Prefix` (`:43-46`). Optional TLS block from `tlsSecretName` (`:28-32`), `cert-manager.io/cluster-issuer` from `certIssuer` (`:20-22`), extra `annotations` (`:23-25`) | The rewrite is nginx-ingress specific |
| `_helpers.tpl` | Names and labels; `troupe-gui.base` strips the trailing slash from `basePath` and returns `""` for `/` (`:31-35`) | |

Values and their effects are tabulated in
[../admin/configuration.md](../admin/configuration.md).

## The base-path contract

Three things must agree (`values.yaml:22-25`; `DECISIONS.md` #29-31):

1. **The image** was built with `TROUPE_GUI_BASE` = some path, which Vite normalised
   and wrote into every asset URL (`apps/desktop/vite.config.ts:16-17`). CI would use
   `vars.GUI_BASE || 'app'` (`ci.yml:109`); the Dockerfile default is `/`
   (`Dockerfile:38`).
2. **`basePath` in the values** equals it. The default is `/app` (`values.yaml:25`).
3. **The Ingress** rewrites `<basePath>/x` to `/x` before nginx sees it
   (`templates/ingress.yaml:12-19`), so the container serves from its root regardless
   of the mount point.

If 1 and 2 disagree, `index.html` loads and every asset 404s — a blank page
(`DECISIONS.md` #30). If the ingress class is not nginx-ingress, the rewrite annotation
is ignored and the same blank page results. Changing the base path is a rebuild, not a
`helm upgrade`.

The bundle uses the same value at runtime for two things: the OIDC redirect URI (origin
+ base path, no trailing slash — `apps/desktop/src/shell.ts:91-95`) and the plane-URL
prefill (the origin, when the base path is not `/` — `shell.ts:105-109`). A GUI at
`/app` on the plane's host is same-origin with the plane, so the CORS allowlist stops
mattering for it (`DECISIONS.md` #29).

## `scripts/deploy`, step by step

A bash script (`scripts/deploy:1`, `set -euo pipefail` at `:17`) run from anywhere; it
`cd`s to the repository root (`:19-21`).

| Step | Line | What happens |
|---|---|---|
| Resolve inputs | `:23-26` | `KUBECONFIG_FILE` (default `.local/kubeconfig.yaml`), `VALUES` (default `.local/values.itminds.yaml`), `NAMESPACE` (default `troupe-system`), `RELEASE` (default `troupe-gui`) |
| Check the files exist | `:28-35` | Exit 1 with a message naming the variable to set |
| Build the Helm arguments | `:37-39` | `helm upgrade --install $RELEASE charts/troupe-gui --kubeconfig … --namespace … --values …`, plus `--set image.tag=$TAG` when `TAG` is set |
| `--dry-run` | `:41-44` | If the first argument is `--dry-run`, run Helm with `--dry-run` and exit 0. Despite the header comment (`:6` "render and diff"), it renders; it does not diff |
| Deploy | `:46` | `helm upgrade --install … --wait --timeout 5m` |
| Print what is running | `:55-58` | `kubectl get pods -l app.kubernetes.io/instance=$RELEASE -o custom-columns=POD,READY,IMAGE(.status.containerStatuses[0].imageID)` — the **digest**, because a reused tag with `IfNotPresent` restarts nothing and `helm upgrade` still reports success (`:48-54`; `REPORT.md:204-211`; `DECISIONS.md` #34) |

Inputs:

| Variable | Default | Line |
|---|---|---|
| `KUBECONFIG_FILE` | `<repo>/.local/kubeconfig.yaml` | `scripts/deploy:23` |
| `VALUES` | `<repo>/.local/values.itminds.yaml` | `:24` |
| `NAMESPACE` | `troupe-system` | `:25` |
| `RELEASE` | `troupe-gui` | `:26` |
| `TAG` | unset — the tag in the values file, else the chart's `appVersion` | `:39`; `templates/deployment.yaml:29` |

Usage (`scripts/deploy:4-6`):

```bash
scripts/deploy --dry-run
```

```bash
TAG=sha-1a2b3c4 scripts/deploy
```

```bash
scripts/deploy
```

Without the `.local/` files, point the variables elsewhere:

```bash
KUBECONFIG_FILE=~/.kube/config VALUES=./my-values.yaml scripts/deploy --dry-run
```

The script needs `helm` and `kubectl` on the path. On Windows it runs under Git Bash.

## The recorded live deployment

`REPORT.md:236-251` records a deployment made on 2026-09-13. **Recorded, not verified
for this audit**: nothing was run against the cluster (AUDIT §5).

| Fact | Recorded value | Source |
|---|---|---|
| URL | `https://troupe.itmindsinternal.dk/app` | `REPORT.md:242` |
| Image | `rg.fr-par.scw.cloud/troupe/troupe-gui:0.1.1`, digest `sha256:ae03b5a9…` | `REPORT.md:247` |
| Release | `troupe-gui`, revision 3, namespace `troupe-system` | `REPORT.md:248` |
| Pods | 2, both ready, both on that digest | `REPORT.md:249` |
| Ingress | host `troupe.itmindsinternal.dk`, path `/app(/\|$)(.*)`, class nginx | `REPORT.md:250` |
| Certificate | `troupe-plane-tls`, shared with the plane's Ingress | `REPORT.md:251` |
| Values | `.local/values.itminds.yaml`, gitignored | AUDIT §1.5 |
| Checked from a browser | page renders; hashed assets `immutable`, `index.html` `no-cache`; deep link falls back; `/.well-known/troupe` same-origin; `/rpc` still reaches the plane; plane URL prefilled | `REPORT.md:253-262` |
| Not yet done | sign-in — the redirect URI `https://troupe.itmindsinternal.dk/app` had to be registered on the Entra application as an SPA redirect | `REPORT.md:264-267` |

Unconfirmed: how `0.1.1` was built and pushed. It is not a tag CI would produce
(`sha-<7>` or a `v*` version), the chart's `appVersion` is `0.1.0`, and no `v*` tag
exists in the history (AUDIT §3.5). The image repository is a Scaleway registry, not the
chart's default `ghcr.io/objective-mj/troupe-gui` (`values.yaml:6`), so the values file
overrides `image.repository`.

## Rollback

`scripts/deploy` has no rollback path. Use Helm directly with the same kubeconfig and
namespace:

```bash
helm --kubeconfig .local/kubeconfig.yaml -n troupe-system history troupe-gui
```

```bash
helm --kubeconfig .local/kubeconfig.yaml -n troupe-system rollback troupe-gui <revision>
```

Or deploy a known-good tag forward:

```bash
TAG=<previous-tag> scripts/deploy
```

Because nothing is stateful (no volume but two `emptyDir`s, `templates/deployment.yaml:52-54`),
a rollback is only a change of image. The digest printout at the end of
`scripts/deploy` is how to confirm which image is actually serving; `helm rollback`
does not print it, so follow with the same `kubectl get pods` line
(`scripts/deploy:56-58`).

## Staging

There is no staging environment in this repository: one values file, one recorded
release, no second host. The local stand-in is `pnpm fake` plus `pnpm dev`
(`README.md:53-58`; [local-setup.md](local-setup.md)), which exercises the client against
the fakes but not the image, the chart or an ingress. Testing a sub-path build end to
end requires a cluster with nginx-ingress; the only one recorded is the live one.

## Related

- [../admin/operations.md](../admin/operations.md) — the same procedures from the
  operator's side, with troubleshooting.
- [../admin/identity-provider.md](../admin/identity-provider.md) — the registration a
  new deployment needs.
- [ci-cd.md](ci-cd.md) — where the image would come from.
