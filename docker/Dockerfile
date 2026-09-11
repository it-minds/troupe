# One Dockerfile for the three server releases. `RELEASE` picks which.
#
# Two stages: build against the full Elixir image, run on a slim Debian with only what
# the release needs at runtime. The client binary is not built here — it is a Burrito
# executable for a user's laptop, and CI builds it on a native runner per target.

ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=28.5.0.5
ARG DEBIAN_VERSION=bookworm-20250908-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build

ARG RELEASE=troupe_operator

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

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
RUN mix deps.get --only prod && mix deps.compile

COPY config config
COPY apps apps
COPY native native

RUN mix compile && mix release ${RELEASE} --overwrite \
 && mv _build/prod/rel/${RELEASE} /app/release

FROM debian:${DEBIAN_VERSION} AS runtime

# `bubblewrap` is the worker's sandbox and `git` is how it clones a source; both are
# harmless in the other images and keep this file to one.
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates git bubblewrap \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

# Non-root, and the uid the operator's pod spec asks for.
RUN groupadd --gid 1000 troupe && useradd --uid 1000 --gid 1000 --create-home troupe
WORKDIR /app
RUN chown troupe:troupe /app
USER troupe:troupe

COPY --from=build --chown=troupe:troupe /app/release ./

ARG RELEASE=troupe_operator
ENV RELEASE_NAME=${RELEASE}

# `exec` so signals reach the VM: Kubernetes' SIGTERM has to become a graceful stop,
# not a killed shell.
ENTRYPOINT ["/bin/sh", "-c", "exec /app/bin/${RELEASE_NAME} start"]
