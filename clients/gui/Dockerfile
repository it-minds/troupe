# The GUI as one static bundle behind nginx.
#
# There is no server here, and that is the point: the GUI is a protocol client, so what
# ships is HTML, CSS and JavaScript, and every call it makes goes to the plane or to a
# worker from the browser. Nothing in this image holds a secret, talks to a database, or
# needs to be told anything at runtime except where it is mounted.
#
#   docker build --build-arg TROUPE_GUI_BASE=app -t troupe-gui .
#
# The value is written without slashes on purpose: a POSIX shell on Windows rewrites a
# leading `/` into a drive path on its way to `--build-arg`, and the result is a bundle
# whose asset URLs begin `/Program Files/Git/app/` — an image that builds perfectly and
# serves nothing. `app`, `/app` and `/app/` are all accepted and mean the same thing.
#
# `TROUPE_GUI_BASE` is baked in at build time because Vite rewrites every asset URL with
# it. An image built for `/app/` is not the same image as one built for `/`, and pretending
# otherwise with a runtime substitution over minified output is the kind of cleverness
# that fails on the one asset the regex missed.

FROM node:24-bookworm-slim AS build

# Corepack pins pnpm to whatever `packageManager` in package.json says, so the build uses
# the same version a developer does rather than whatever is newest today.
RUN corepack enable

WORKDIR /src

# Manifests first: the dependency layer is then cached until a manifest actually changes,
# which is the difference between a ten second rebuild and a two minute one.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY packages/client/package.json packages/client/
COPY packages/bench/package.json packages/bench/
COPY apps/desktop/package.json apps/desktop/
RUN pnpm install --frozen-lockfile

COPY . .

ARG TROUPE_GUI_BASE=/
ENV TROUPE_GUI_BASE=${TROUPE_GUI_BASE}

# Typecheck and test on the way through. An image that builds from code that does not
# typecheck is an image nobody can reason about, and the suite is eight seconds.
RUN pnpm --filter @troupe/client build \
 && pnpm --filter @troupe/client test \
 && pnpm --filter @troupe/desktop build


FROM nginxinc/nginx-unprivileged:1.29-alpine AS runtime

# Unprivileged: the image runs as uid 101 and listens on 8080, so the Pod needs no
# capability to bind a port and no root in the container.
COPY --from=build /src/apps/desktop/dist /usr/share/nginx/html
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 8080

# A container that cannot serve its own index is not ready, and saying so is one line.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD ["/bin/sh", "-c", "wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1"]
