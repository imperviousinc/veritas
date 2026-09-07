//! Public JSON-RPC front door on the spaced port.
//!
//! `queryhandle` is served here; every other method is forwarded to the
//! embedded spaced backend.

use crate::query_handle;
use hyper::body::Bytes;
use hyper::header::{AUTHORIZATION, CONTENT_TYPE, HOST};
use hyper::http::request::Parts;
use hyper::service::{make_service_fn, service_fn};
use hyper::{Body, Client, Method, Request, Response, StatusCode};
use serde_json::{json, Value};
use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::Arc;

struct ProxyState {
    backend: String,
    expected_auth: String,
    http: Client<hyper::client::HttpConnector, Body>,
}

pub async fn run(
    bind: SocketAddr,
    backend: String,
    rpc_user: String,
    rpc_password: String,
    mut shutdown: tokio::sync::broadcast::Receiver<()>,
) -> anyhow::Result<()> {
    let token = spaces_client::auth::auth_token_from_creds(&rpc_user, &rpc_password);
    let state = Arc::new(ProxyState {
        backend: backend.trim_end_matches('/').to_string(),
        expected_auth: format!("Basic {token}"),
        http: Client::new(),
    });

    let make_svc = {
        let state = state.clone();
        make_service_fn(move |_| {
            let state = state.clone();
            async move {
                Ok::<_, Infallible>(service_fn(move |req| {
                    let state = state.clone();
                    async move { Ok::<_, Infallible>(handle(state, req).await) }
                }))
            }
        })
    };

    let server = hyper::Server::bind(&bind)
        .serve(make_svc)
        .with_graceful_shutdown(async move {
            let _ = shutdown.recv().await;
        });

    tracing::info!("RPC proxy listening on {bind} (backend {backend})");
    server.await?;
    Ok(())
}

async fn handle(state: Arc<ProxyState>, req: Request<Body>) -> Response<Body> {
    if req.method() != Method::POST {
        return forward(&state, req).await;
    }

    let (parts, body) = req.into_parts();
    let bytes = match hyper::body::to_bytes(body).await {
        Ok(b) => b,
        Err(e) => return rpc_error(Value::Null, -32700, &format!("read body: {e}")),
    };

    let payload: Value = match serde_json::from_slice(&bytes) {
        Ok(v) => v,
        Err(_) => {
            return forward(
                &state,
                Request::from_parts(parts, Body::from(bytes)),
            )
            .await;
        }
    };

    let method = payload.get("method").and_then(Value::as_str).unwrap_or("");
    if method != "queryhandle" && method != "query_handle" {
        if method == "rpc.discover" {
            return discover(&state, parts, bytes, payload).await;
        }
        return forward(&state, Request::from_parts(parts, Body::from(bytes))).await;
    }

    if !authorized(&parts.headers, &state.expected_auth) {
        let id = payload.get("id").cloned().unwrap_or(Value::Null);
        let mut resp = rpc_error(id, -32001, "Unauthorized: copy RPC credentials from Settings");
        *resp.status_mut() = StatusCode::UNAUTHORIZED;
        resp.headers_mut().insert(
            "WWW-Authenticate",
            hyper::header::HeaderValue::from_static("Basic realm=\"veritas\""),
        );
        return resp;
    }

    let id = payload.get("id").cloned().unwrap_or(Value::Null);
    let handle = match handle_param(payload.get("params").unwrap_or(&Value::Null)) {
        Ok(h) => h,
        Err(msg) => return rpc_error(id, -32602, &msg),
    };

    if query_handle::is_space_name(&handle) {
        let space = query_handle::normalize_space(&handle);
        tracing::info!("queryhandle {handle} is a space; forwarding getspace {space}");
        return forward_getspace(state, parts, id, space).await;
    }

    match query_handle::query(&handle).await {
        Ok(mut result) => {
            if let Some(num_id) = result.num_id.clone() {
                if let Some(fb) = backend_rpc(&state, "getfallback", json!([num_id])).await {
                    if let Some(recs) = query_handle::fallback_records_from_rpc(&fb) {
                        tracing::info!("queryhandle {handle} num {num_id} has on-chain fallback");
                        result.set_handle_fallback(recs);
                    }
                }
            }
            rpc_ok(id, serde_json::to_value(result).unwrap_or(Value::Null))
        }
        Err(msg) => rpc_error(id, -32000, &msg),
    }
}

async fn backend_rpc(state: &ProxyState, method: &str, params: Value) -> Option<Value> {
    let body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    });
    let req = Request::builder()
        .method(Method::POST)
        .uri(state.backend.clone())
        .header(CONTENT_TYPE, "application/json")
        .header(AUTHORIZATION, state.expected_auth.as_str())
        .body(Body::from(body.to_string()))
        .ok()?;
    let resp = state.http.request(req).await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let bytes = hyper::body::to_bytes(resp.into_body()).await.ok()?;
    let v: Value = serde_json::from_slice(&bytes).ok()?;
    let result = v.get("result")?.clone();
    if result.is_null() {
        None
    } else {
        Some(result)
    }
}

async fn forward_getspace(
    state: Arc<ProxyState>,
    mut parts: Parts,
    id: Value,
    space: String,
) -> Response<Body> {
    let body = json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "getspace",
        "params": [space],
    })
    .to_string();
    parts.headers.remove(hyper::header::CONTENT_LENGTH);
    if !parts.headers.contains_key(CONTENT_TYPE) {
        parts.headers.insert(CONTENT_TYPE, hyper::header::HeaderValue::from_static("application/json"));
    }
    forward(&state, Request::from_parts(parts, Body::from(body))).await
}

async fn discover(
    state: &ProxyState,
    parts: Parts,
    bytes: Bytes,
    payload: Value,
) -> Response<Body> {
    let mut resp = forward(state, Request::from_parts(parts, Body::from(bytes))).await;
    if !resp.status().is_success() {
        return resp;
    }
    let body = match hyper::body::to_bytes(resp.body_mut()).await {
        Ok(b) => b,
        Err(_) => return resp,
    };
    let mut json: Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(_) => {
            return Response::builder()
                .status(StatusCode::OK)
                .header(CONTENT_TYPE, "application/json")
                .body(Body::from(body))
                .unwrap();
        }
    };
    if let Some(methods) = json
        .pointer_mut("/result/methods")
        .and_then(Value::as_array_mut)
    {
        if !methods.iter().any(|m| m.as_str() == Some("queryhandle")) {
            methods.push(json!("queryhandle"));
        }
    }
    let id = payload.get("id").cloned().unwrap_or(Value::Null);
    if json.get("id").is_none() {
        json["id"] = id;
    }
    Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, "application/json")
        .body(Body::from(json.to_string()))
        .unwrap()
}

async fn forward(state: &ProxyState, req: Request<Body>) -> Response<Body> {
    let (mut parts, body) = req.into_parts();
    let path = parts
        .uri
        .path_and_query()
        .map(|p| p.as_str())
        .unwrap_or("/");
    let uri = format!("{}{}", state.backend, path);
    parts.uri = match uri.parse() {
        Ok(u) => u,
        Err(e) => {
            return Response::builder()
                .status(StatusCode::BAD_GATEWAY)
                .body(Body::from(format!("bad backend uri: {e}")))
                .unwrap();
        }
    };
    parts.headers.remove(HOST);
    let fwd = Request::from_parts(parts, body);
    match state.http.request(fwd).await {
        Ok(resp) => resp,
        Err(e) => Response::builder()
            .status(StatusCode::BAD_GATEWAY)
            .body(Body::from(format!("spaced backend: {e}")))
            .unwrap(),
    }
}

fn authorized(headers: &hyper::HeaderMap, expected: &str) -> bool {
    headers
        .get(AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v == expected)
}

fn handle_param(params: &Value) -> Result<String, String> {
    match params {
        Value::Array(arr) => {
            let first = arr.first().ok_or("missing handle")?;
            first
                .as_str()
                .map(str::to_string)
                .or_else(|| {
                    first
                        .get("handle")
                        .and_then(Value::as_str)
                        .map(str::to_string)
                })
                .ok_or_else(|| "expected handle string".into())
        }
        Value::Object(map) => map
            .get("handle")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| "expected params.handle".into()),
        _ => Err("params must be [handle]".into()),
    }
}

fn rpc_ok(id: Value, result: Value) -> Response<Body> {
    json_response(json!({"jsonrpc": "2.0", "id": id, "result": result}))
}

fn rpc_error(id: Value, code: i64, message: &str) -> Response<Body> {
    json_response(json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": code, "message": message }
    }))
}

fn json_response(value: Value) -> Response<Body> {
    Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, "application/json")
        .body(Body::from(value.to_string()))
        .unwrap()
}
