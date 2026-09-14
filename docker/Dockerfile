# One Dockerfile for the four server releases. `RELEASE` picks which.
#
# Two stages: build against the full Elixir image, run on a slim Debian with only what
# the release needs at runtime. The client binary is not built here — it is a Burrito
# executable for a user's laptop, and CI builds it on a native runner per target.

ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=28.5.0.5
ARG DEBIAN_VERSION=bookworm-20260824-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build

ARG RELEASE=troupe_operator

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*

# Zig, for the worker alone. `reaper` is the process supervisor every OS process the
# worker starts runs under, and `mix compile.reaper` builds it — or, with no Zig on
# PATH, prints a warning and builds nothing. The image then starts perfectly well and
# answers every `shell` call with `:reaper_missing`, a failure that only ever shows up
# in a pod. A laptop's prebuilt `priv/reaper` cannot stand in: `.dockerignore` excludes
# it on purpose, because it would be the wrong architecture under the right name. Same
# version Burrito pins, so one toolchain builds the reaper everywhere.
ARG ZIG_VERSION=0.16.0
RUN if [ "${RELEASE}" = "troupe_worker" ]; then \
      set -eux; \
      arch="$(uname -m)"; \
      curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" \
        -o /tmp/zig.tar.xz; \
      mkdir -p /opt/zig; \
      tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
      rm /tmp/zig.tar.xz; \
      /opt/zig/zig version; \
    fi
ENV PATH="/opt/zig:${PATH}"

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

# Dependencies first, so a change to the source does not refetch them.
COPY mix.exs mix.lock ./
COPY apps/troupe_core/mix.exs apps/troupe_core/
COPY apps/troupe_protocol/mix.exs apps/troupe_protocol/
COPY apps/troupe_gateway/mix.exs apps/troupe_gateway/
COPY apps/troupe_tui/mix.exs apps/troupe_tui/
COPY apps/troupe_ctl/mix.exs apps/troupe_ctl/
COPY apps/troupe_worker/mix.exs apps/troupe_worker/
COPY apps/troupe_plane/mix.exs apps/troupe_plane/
COPY apps/troupe_operator/mix.exs apps/troupe_operator/
COPY apps/troupe_a2a/mix.exs apps/troupe_a2a/
# Fetching only. `mix deps.compile` cannot run here: in an umbrella the sibling apps are
# path dependencies, so it tries to compile `troupe_core` before any of its source has
# been copied and fails. What this layer is worth is the *fetch* — the part that needs
# the network — and that is cached on `mix.lock` alone, which is the point.
RUN mix deps.get --only prod

COPY config config
COPY apps apps
COPY native native

RUN mix deps.compile && mix compile && mix release ${RELEASE} --overwrite \
 && mv _build/prod/rel/${RELEASE} /app/release

# The reaper is the one thing in this image whose absence is silent, so it is checked
# here rather than discovered by the first `shell` call in a pod.
RUN if [ "${RELEASE}" = "troupe_worker" ]; then \
      ls /app/release/lib/troupe_core-*/priv/reaper/x86_64-linux-musl/reaper \
        || { echo "the worker release has no reaper: mix compile.reaper built nothing" >&2; exit 1; }; \
    fi

FROM debian:${DEBIAN_VERSION} AS runtime

ARG RELEASE=troupe_operator

# `bubblewrap` is the worker's sandbox and `git` is how it clones a source. Neither has
# a job in the plane or the operator, and a namespace-juggling sandbox helper and a
# network client are the two things one would least like to find in the image that is
# internet-facing and the image that holds every cluster privilege — so they go into
# the worker image alone, and this stays one Dockerfile.
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates \
      $(if [ "${RELEASE}" = "troupe_worker" ]; then echo git bubblewrap; fi) \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

# Non-root, and the uid the operator's pod spec asks for.
RUN groupadd --gid 1000 troupe && useradd --uid 1000 --gid 1000 --create-home troupe
WORKDIR /app
RUN chown troupe:troupe /app
USER troupe:troupe

COPY --from=build --chown=troupe:troupe /app/release ./

ENV RELEASE_NAME=${RELEASE}

# `exec` so signals reach the VM: Kubernetes' SIGTERM has to become a graceful stop,
# not a killed shell.
ENTRYPOINT ["/bin/sh", "-c", "exec /app/bin/${RELEASE_NAME} start"]
