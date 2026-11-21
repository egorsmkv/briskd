# ircd-search: the Tantivy message index behind ircd's egorsmkv.github.io/search
# extension (see docs/search.md).
FROM rust:1.99.0-slim-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
# Fetch and build the dependencies once, cached apart from the sources.
RUN mkdir src && echo "fn main() {}" > src/main.rs \
    && cargo build --release --locked && rm -rf src
COPY src ./src
RUN touch src/main.rs && cargo build --release --locked

FROM debian:bookworm-slim
RUN useradd --system --uid 10001 --home /data search \
    && mkdir -p /data/index && chown -R search /data
COPY --from=build /src/target/release/ircd-search /usr/local/bin/ircd-search
USER search
ENV SEARCH_ADDR=0.0.0.0:7700 SEARCH_DIR=/data/index
EXPOSE 7700
VOLUME /data
ENTRYPOINT ["/usr/local/bin/ircd-search"]
