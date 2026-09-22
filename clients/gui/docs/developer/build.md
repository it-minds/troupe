> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).
> The GUI now lives at `clients/gui` in the Troupe repository, and this directory is still the image's whole build context; the chart and CI below are the root's (root Decisions 666, 670).

# Build

From source to a static bundle, and from the bundle to an nginx image.

## `pnpm build`

`pnpm -r build` (`package.json:7`) runs each package's `build` script in dependency
order:

| Package | Script | Output |
|---|---|---|
| `@troupe/client` | `tsc -p tsconfig.json` (`packages/client/package.json:18`) | `packages/client/dist/` — JS, `.d.ts` and source maps from `src/` (`tsconfig.json:4-5`, `tsconfig.base.json:13-14`). This is what the package's `main`/`types`/`exports` point at (`package.json:6-13`) |
| `@troupe/bench` | none | — (`packages/bench/package.json:6-9` has only `start` and `typecheck`) |
| `@troupe/desktop` | `tsc -p tsconfig.json --noEmit && vite build` (`apps/desktop/package.json:8`) | `apps/desktop/dist/` — `index.html` plus hashed assets; `target: es2022`, source maps on (`vite.config.ts:31`) |

The desktop build does not consume `packages/client/dist`: both `tsc` and Vite are
aliased to `packages/client/src/index.ts` (`apps/desktop/tsconfig.json:17-19`,
`vite.config.ts:22-29`; `DECISIONS.md` #17, #26). The client's `dist` matters to the
bench, whose `tsconfig.json` has no alias (`packages/bench/tsconfig.json:1-4`).

### The base path

`TROUPE_GUI_BASE` is read once, at build time (`apps/desktop/vite.config.ts:16-17`):

```
raw  = (process.env.TROUPE_GUI_BASE ?? "/").trim()
base = raw === "" || raw === "/"  ?  "/"  :  "/" + raw.replace(/^\/+|\/+$/g, "") + "/"
```

So `app`, `/app` and `/app/` all become `/app/`, and unset, `""` or `/` become `/`. Vite
writes `base` into every asset URL and exposes it as `import.meta.env.BASE_URL`, which
`shell.ts` uses for the redirect URI and the plane-URL prefill
(`apps/desktop/src/shell.ts:91-109`). An image built for `/app/` cannot be served at `/`
and vice versa (`DECISIONS.md` #30). The value is documented without a leading slash
because a POSIX shell on Windows rewrites `/app` into a drive path on its way to
`--build-arg` (`Dockerfile:10-13`; `DECISIONS.md` #32).

The chart's `gui.basePath` must equal what was baked in (the root
`charts/troupe/values.yaml`); see [deployment.md](deployment.md).

## The Dockerfile, stage by stage

```bash
docker build --build-arg TROUPE_GUI_BASE=app -t troupe-gui .
```

| Lines | Stage | What happens |
|---|---|---|
| `Dockerfile:20` | `build` | `FROM node:24-bookworm-slim` |
| `:24` | | `corepack enable`, so pnpm is the version `packageManager` names (`:22-23`) |
| `:26` | | `WORKDIR /src` |
| `:30-33` | | Copy the root manifests and the three package manifests only, so the install layer caches until a manifest changes (`:28-29`) |
| `:34` | | `pnpm install --frozen-lockfile` |
| `:36` | | `COPY . .` — the whole context, filtered by `.dockerignore` |
| `:38-39` | | `ARG TROUPE_GUI_BASE=/` and `ENV` of the same, so Vite sees it |
| `:43-45` | | `pnpm --filter @troupe/client build && pnpm --filter @troupe/client test && pnpm --filter @troupe/desktop build`. **The image runs the client's 33 tests**; a failing test fails the build (`:41-42`; `DECISIONS.md` #33). The desktop build's `tsc --noEmit` is the typecheck. The bench is neither built nor typechecked here |
| `:48` | `runtime` | `FROM nginxinc/nginx-unprivileged:1.29-alpine` |
| `:52` | | `COPY --from=build /src/apps/desktop/dist /usr/share/nginx/html` — only the bundle crosses over |
| `:53` | | `COPY docker/nginx.conf /etc/nginx/conf.d/default.conf` |
| `:55` | | `EXPOSE 8080` |
| `:58-59` | | `HEALTHCHECK` every 30 s: `wget -q -O /dev/null http://127.0.0.1:8080/healthz` |

The runtime image runs as uid 101 and listens on 8080 (`Dockerfile:50-51`); the chart
relies on both (the root `charts/troupe/templates/gui-deployment.yaml`).

Unconfirmed: the chart's comment on `gui.replicas` calls the image "30 MB of nginx". No
image size was measured for the audit.

## `docker/nginx.conf`

| Lines | Behaviour |
|---|---|
| `:13-15` | `listen 8080`, `root /usr/share/nginx/html` |
| `:19-20` | `real_ip_header X-Forwarded-For` from any address — the ingress terminates TLS and is the only thing in front (`:17-18`) |
| `:23-25` | `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`, all `always` |
| `:27-29` | gzip for CSS, JS, JSON, SVG over 1 KiB |
| `:33-37` | `location = /healthz` → `200 "ok\n"`, access log off; declared before the fallback so it never serves the app |
| `:41-45` | `\.(js\|css\|woff2?\|png\|jpe?g\|gif\|svg\|ico\|webp\|map)$` → `expires 1y`, `Cache-Control: public, immutable`, `try_files $uri =404`. Safe because Vite content-hashes filenames (`:39-40`) |
| `:47-50` | `location /` → `Cache-Control: no-cache`, `try_files $uri $uri/ /index.html` — the SPA fallback. `index.html` is the one file that must never be cached (`:8-10`) |

There is no `Content-Security-Policy` header and no HSTS; the latter would be the
ingress's job. Nothing in the config depends on the base path: the ingress strips it
(`DECISIONS.md` #31).

## `.dockerignore` and the `.local/` gap

`.dockerignore:1-9` excludes `node_modules`, `**/node_modules`, `**/dist`, `.git`,
`.github`, `charts`, `docs/design/example.dc.html`, `bench-results`, `*.tsbuildinfo`.

It does **not** exclude `.local/` (AUDIT §3.1). `COPY . .` at `Dockerfile:36` therefore
copies `.local/kubeconfig.yaml` and `.local/values.itminds.yaml` into the build stage of
any image built on a machine that has them. The runtime image copies only
`apps/desktop/dist` (`Dockerfile:52`), so the files do not ship — but they sit in an
intermediate layer in the local Docker cache, and in CI's `type=gha` cache if a runner
ever had them (CI runners do not). Adding `.local` to `.dockerignore` is a one-line fix
not made at audit time. Since the move the deploy credentials live in the repository
root's `.local/`, which the root `scripts/deploy` reads and which is outside this build
context, so the gap only matters for a `clients/gui/.local/` somebody makes by hand.

It also does not exclude `docs/` or `spec.md`; they are copied into the build stage and
discarded with it.

## Building locally

The documented form (`Dockerfile:8`, `README.md:107`):

```bash
docker build --build-arg TROUPE_GUI_BASE=app -t troupe-gui .
```

For a root-mounted build, omit the argument (default `/`, `Dockerfile:38`):

```bash
docker build -t troupe-gui .
```

Run it and check the health endpoint:

```bash
docker run --rm -p 8080:8080 troupe-gui
```

```bash
curl -i http://127.0.0.1:8080/healthz
```

An image built with `TROUPE_GUI_BASE=app` and run directly like this serves
`index.html` at `/` but its asset URLs begin `/app/`, so the page is blank outside an
ingress that rewrites the prefix. That is expected (`DECISIONS.md` #31): test a
sub-path build behind the chart, or build with `/` for a direct run.

On Git Bash for Windows, `MSYS_NO_PATHCONV=1` is not needed for the build argument
because of the normalisation, but is for any `-v /path` mount (`docs/bench.md:51-52`).

## What CI builds

The `images` job of the root `.github/workflows/ci.yml` builds this Dockerfile with
`clients/gui` as the whole context and
`TROUPE_GUI_BASE=${{ vars.GUI_BASE || 'app' }}`, for `linux/amd64`, and pushes it as
`sha-<short>` on every push to `main`; a release promotes that image to its version rather
than building another. `scripts/build-images` at the root builds the same image, with
`/app`, for the kind cluster. See [ci-cd.md](ci-cd.md).

## Related

- [deployment.md](deployment.md) — the chart that serves the image.
- [../admin/configuration.md](../admin/configuration.md) — the nginx behaviours an
  operator cares about.
