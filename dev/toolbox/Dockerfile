# The toolchain, for a machine that has none.
#
# `.tool-versions` names Erlang 28.5.0.5, Elixir 1.20.4 and Zig 0.16.0, and CI installs
# exactly those. A developer without them — or on Windows, where bubblewrap and the
# reaper's Linux triples do not exist — gets the same three from this image instead, and
# runs the suite against `dev/docker-compose.yml` over the compose network.
#
# This is not a deployment artifact. `docker/Dockerfile` builds those.
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=28.5.0.5
ARG DEBIAN_VERSION=bookworm-20260824-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}

# build-essential and git: Hex packages with NIFs. inotify-tools: the native watch
# backend, without which the watch done item is proven by polling and is therefore not
# proven. bubblewrap: `Troupe.SandboxTest` is the only proof one session cannot see
# another's workspace. socat: the configuration names `localhost:55432`,
# `localhost:59000` and `localhost:58200`, and inside a container those three loopback
# ports have to be carried to the compose network — see `dev/toolbox/entrypoint`.
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      build-essential git ca-certificates curl xz-utils \
      inotify-tools bubblewrap socat postgresql-client jq \
 && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.16.0
RUN set -eux; \
    arch="$(uname -m)"; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" \
      -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    zig version

RUN mix local.hex --force && mix local.rebar --force

COPY entrypoint /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["bash"]
