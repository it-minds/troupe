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
# another's workspace. socat: the configuration names `localhost:25432`,
# `localhost:29000` and `localhost:28200`, and inside a container those three loopback
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

# kubectl, because `mix troupe.e2e` drives a cluster with it and because asserting
# through the same client library the operator uses would hide a whole class of failure —
# a wrong RBAC rule, a missing CRD field, an object the operator only believes it wrote.
# A second road to the same API server is the point. Helm comes with it so that an
# upgrade mid-session is a fault the suite can inject rather than a step done by hand.
ARG KUBECTL_VERSION=v1.34.0
ARG HELM_VERSION=v3.19.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" \
      -o /usr/local/bin/kubectl; \
    chmod +x /usr/local/bin/kubectl; \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz" -o /tmp/helm.tgz; \
    tar -xzf /tmp/helm.tgz -C /tmp; \
    mv "/tmp/linux-${arch}/helm" /usr/local/bin/helm; \
    rm -rf /tmp/helm.tgz "/tmp/linux-${arch}"; \
    kubectl version --client=true; \
    helm version --short

RUN mix local.hex --force && mix local.rebar --force

COPY entrypoint /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["bash"]
