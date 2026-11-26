# rtpflux media relay for WebIRC calls (development and testing):
# https://github.com/RustedBytes/rtpflux (GPL-3.0-only). It speaks
# rtpengine's NG control protocol, so briskd's `calls` client is unchanged.
# rtpflux publishes no image or release yet, so this builds a pinned commit.
# To update it, change RTPFLUX_COMMIT and RTPFLUX_SHA256 together:
#   curl -sSL https://github.com/RustedBytes/rtpflux/archive/<commit>.tar.gz | sha256sum

# --- build ----------------------------------------------------------------
# The toolchain rtpflux pins in rust-toolchain.toml at that commit.
FROM docker.io/library/rust:1.100.0-slim-trixie AS build
ARG RTPFLUX_COMMIT=a2726888600683dfe4357c48a9c5c8aa56018a7f
ARG RTPFLUX_SHA256=01b72bf8ffc7913dbad3fb51a1762d28598d4e06b435ecbe13a38e7d84fd4776
ENV RUSTUP_TOOLCHAIN=1.100.0 \
    CARGO_TERM_COLOR=never
ADD https://github.com/RustedBytes/rtpflux/archive/${RTPFLUX_COMMIT}.tar.gz /rtpflux.tar.gz
WORKDIR /src
RUN echo "${RTPFLUX_SHA256}  /rtpflux.tar.gz" | sha256sum -c - \
    && tar xzf /rtpflux.tar.gz --strip-components=1 \
    && cargo build --release --locked -p rtpflux \
    && install -D -m 755 target/release/rtpflux /out/rtpflux

# --- run ------------------------------------------------------------------
FROM docker.io/library/debian:trixie-slim
RUN useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin rtpflux
COPY --from=build /out/rtpflux /usr/bin/rtpflux
COPY entrypoint.sh /usr/local/bin/rtpflux-entrypoint
USER rtpflux
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/rtpflux-entrypoint"]
