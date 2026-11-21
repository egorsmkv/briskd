# ircd-search: the Tantivy message index behind ircd's egorsmkv.github.io/search
# extension (see docs/search.md).
FROM rust:1.99.0-alpine3.24 AS build
# A C toolchain for crates with build scripts; the binary links musl statically.
RUN apk add --no-cache musl-dev
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
# Fetch and build the dependencies once, cached apart from the sources.
RUN mkdir src && echo "fn main() {}" > src/main.rs \
    && cargo build --release --locked && rm -rf src
COPY src ./src
RUN touch src/main.rs && cargo build --release --locked

FROM alpine:3.24.4
RUN addgroup -S -g 10001 search \
    && adduser -S -D -H -u 10001 -G search -h /data search \
    && mkdir -p /data/index && chown -R search:search /data
COPY --from=build /src/target/release/ircd-search /usr/local/bin/ircd-search
COPY LICENSE /usr/share/doc/ircd-search/LICENSE
USER search
ENV SEARCH_ADDR=0.0.0.0:7700 SEARCH_DIR=/data/index
EXPOSE 7700
VOLUME /data
ENTRYPOINT ["/usr/local/bin/ircd-search"]
