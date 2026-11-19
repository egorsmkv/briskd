FROM erlang:29.1.2

ARG REBAR3_VERSION=3.28.0
ARG JUST_VERSION=1.43.1
ARG DENO_VERSION=2.2.10
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tar unzip \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
        amd64) just_arch=x86_64; deno_arch=x86_64 ;; \
        arm64) just_arch=aarch64; deno_arch=aarch64 ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-${just_arch}-unknown-linux-musl.tar.gz" \
        -o /tmp/just.tar.gz; \
    tar -xzf /tmp/just.tar.gz -C /usr/local/bin just; \
    rm /tmp/just.tar.gz; \
    curl -fsSL "https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/deno-${deno_arch}-unknown-linux-gnu.zip" \
        -o /tmp/deno.zip; \
    unzip -q /tmp/deno.zip -d /usr/local/bin deno; \
    rm /tmp/deno.zip; \
    curl -fsSL "https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3" \
        -o /usr/local/bin/rebar3; \
    chmod +x /usr/local/bin/just /usr/local/bin/deno /usr/local/bin/rebar3; \
    just --version; \
    deno --version; \
    rebar3 version

WORKDIR /workspace

CMD ["just", "run-config", "config/ircd.dev.json"]
