FROM erlang:29.1.2

ARG REBAR3_VERSION=3.28.0
ARG JUST_VERSION=1.43.1
ARG DENO_VERSION=2.9.8
# ELP (WhatsApp Erlang Language Platform): linter, eqWAlizer type checker, and
# language server. Release tag, built for OTP 29.1; checksums per architecture.
ARG ELP_VERSION=2026-10-14
ARG ELP_SHA256_AMD64=3251f2d3550adf28f33529686103fabb1fbf0b0e7deb5cd06b93dab06b8647ea
ARG ELP_SHA256_ARM64=c15b7760222d9fed417b996790cd14aaf949fbe3ef113240bddc2fa7e73aec21
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates cmake curl tar unzip \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
        amd64) just_arch=x86_64; deno_arch=x86_64; elp_sha="${ELP_SHA256_AMD64}" ;; \
        arm64) just_arch=aarch64; deno_arch=aarch64; elp_sha="${ELP_SHA256_ARM64}" ;; \
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
    curl -fsSL "https://github.com/WhatsApp/erlang-language-platform/releases/download/${ELP_VERSION}/elp-linux-${just_arch}-unknown-linux-gnu-otp-29.1.tar.gz" \
        -o /tmp/elp.tar.gz; \
    echo "${elp_sha}  /tmp/elp.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/elp.tar.gz -C /usr/local/bin elp; \
    rm /tmp/elp.tar.gz; \
    curl -fsSL "https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3" \
        -o /usr/local/bin/rebar3; \
    chmod +x /usr/local/bin/just /usr/local/bin/deno /usr/local/bin/elp /usr/local/bin/rebar3; \
    just --version; \
    deno --version; \
    elp version; \
    rebar3 version

WORKDIR /workspace

CMD ["just", "run-config", "config/briskd.dev.json"]
