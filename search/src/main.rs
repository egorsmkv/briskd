//! briskd-search: the message search service behind briskd's
//! `egorsmkv.github.io/search` extension.
//!
//! An HTTP/JSON service over a Tantivy index (see `index.rs`). briskd mirrors
//! its stored history into it with `POST /index` and runs searches with
//! `POST /search`, naming the conversations the searching user may read;
//! the service never decides access. `GET /health` reports readiness, the
//! document and segment counts, and the index size on disk in bytes.
//!
//! Configuration (environment):
//! - `SEARCH_ADDR`: listen address, default `0.0.0.0:7700`.
//! - `SEARCH_DIR`: index directory, default `/data/index`.
//! - `SEARCH_TOKEN`: when set, every request must carry
//!   `Authorization: Bearer <token>` (compared in constant time).

mod index;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use axum::extract::{DefaultBodyLimit, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::json;

use index::{Error, MessageIndex, Op, SearchRequest};

/// Largest request body, bytes (an index batch of a few thousand messages).
const MAX_BODY: usize = 32 * 1024 * 1024;

struct AppState {
    index: MessageIndex,
    token: Option<String>,
}

type Shared = Arc<AppState>;

#[derive(Deserialize)]
struct IndexRequest {
    ops: Vec<Op>,
}

fn authorized(state: &AppState, headers: &HeaderMap) -> bool {
    let Some(expected) = &state.token else {
        return true;
    };
    let given = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("");
    constant_time_eq(given.as_bytes(), expected.as_bytes())
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn error(status: StatusCode, reason: &str) -> Response {
    (status, Json(json!({ "error": reason }))).into_response()
}

fn index_error(e: Error) -> Response {
    match e {
        Error::Invalid(what) => error(StatusCode::BAD_REQUEST, what),
        Error::Index(e) => {
            eprintln!(
                "{{\"event\":\"index_error\",\"reason\":{:?}}}",
                e.to_string()
            );
            error(StatusCode::INTERNAL_SERVER_ERROR, "index")
        }
    }
}

async fn health(State(state): State<Shared>, headers: HeaderMap) -> Response {
    if !authorized(&state, &headers) {
        return error(StatusCode::UNAUTHORIZED, "unauthorized");
    }
    Json(json!({
        "status": "ok",
        "docs": state.index.len(),
        "segments": state.index.segments(),
        "bytes": state.index.disk_bytes(),
    }))
    .into_response()
}

async fn apply(
    State(state): State<Shared>,
    headers: HeaderMap,
    Json(req): Json<IndexRequest>,
) -> Response {
    if !authorized(&state, &headers) {
        return error(StatusCode::UNAUTHORIZED, "unauthorized");
    }
    let count = req.ops.len();
    let shared = state.clone();
    // Indexing and commits do blocking IO: keep them off the async workers.
    match tokio::task::spawn_blocking(move || shared.index.apply(req.ops)).await {
        Ok(Ok(())) => Json(json!({ "applied": count })).into_response(),
        Ok(Err(e)) => index_error(e),
        Err(_) => error(StatusCode::INTERNAL_SERVER_ERROR, "worker"),
    }
}

async fn search(
    State(state): State<Shared>,
    headers: HeaderMap,
    Json(req): Json<SearchRequest>,
) -> Response {
    if !authorized(&state, &headers) {
        return error(StatusCode::UNAUTHORIZED, "unauthorized");
    }
    let shared = state.clone();
    match tokio::task::spawn_blocking(move || shared.index.search(&req)).await {
        Ok(Ok(res)) => Json(res).into_response(),
        Ok(Err(e)) => index_error(e),
        Err(_) => error(StatusCode::INTERNAL_SERVER_ERROR, "worker"),
    }
}

fn router(state: Shared) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/index", post(apply))
        .route("/search", post(search))
        .layer(DefaultBodyLimit::max(MAX_BODY))
        .with_state(state)
}

async fn shutdown() {
    let ctrl_c = tokio::signal::ctrl_c();
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("SIGTERM handler");
    tokio::select! {
        _ = ctrl_c => {},
        _ = term.recv() => {},
    }
}

#[tokio::main]
async fn main() {
    let addr: SocketAddr = std::env::var("SEARCH_ADDR")
        .unwrap_or_else(|_| "0.0.0.0:7700".into())
        .parse()
        .expect("SEARCH_ADDR must be host:port");
    let dir = PathBuf::from(std::env::var("SEARCH_DIR").unwrap_or_else(|_| "/data/index".into()));
    let token = std::env::var("SEARCH_TOKEN").ok().filter(|t| !t.is_empty());
    let index =
        MessageIndex::open(&dir).unwrap_or_else(|e| panic!("cannot open index {dir:?}: {e:?}"));
    let docs = index.len();
    let state = Arc::new(AppState { index, token });
    let listener = tokio::net::TcpListener::bind(addr).await.expect("bind");
    eprintln!(
        "{{\"event\":\"listening\",\"addr\":\"{addr}\",\"docs\":{docs},\"auth\":{}}}",
        state.token.is_some()
    );
    axum::serve(listener, router(state))
        .with_graceful_shutdown(shutdown())
        .await
        .expect("server");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_comparison() {
        assert!(constant_time_eq(b"secret", b"secret"));
        assert!(!constant_time_eq(b"secret", b"secreT"));
        assert!(!constant_time_eq(b"secret", b"secret-longer"));
    }
}
