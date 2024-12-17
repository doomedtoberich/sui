// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};

use crate::{
    rest::content_type::ContentType,
    rest::APPLICATION_BCS,
    rest::TEXT_PLAIN_UTF_8,
    types::{
        X_SUI_CHAIN, X_SUI_CHAIN_ID, X_SUI_CHECKPOINT_HEIGHT, X_SUI_EPOCH,
        X_SUI_LOWEST_AVAILABLE_CHECKPOINT, X_SUI_LOWEST_AVAILABLE_CHECKPOINT_OBJECTS,
        X_SUI_TIMESTAMP_MS,
    },
    RpcService,
};

pub struct Bcs<T>(pub T);

impl<T> axum::response::IntoResponse for Bcs<T>
where
    T: serde::Serialize,
{
    fn into_response(self) -> axum::response::Response {
        match bcs::to_bytes(&self.0) {
            Ok(buf) => (
                [(
                    axum::http::header::CONTENT_TYPE,
                    axum::http::HeaderValue::from_static(APPLICATION_BCS),
                )],
                buf,
            )
                .into_response(),
            Err(err) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                [(
                    axum::http::header::CONTENT_TYPE,
                    axum::http::HeaderValue::from_static(TEXT_PLAIN_UTF_8),
                )],
                err.to_string(),
            )
                .into_response(),
        }
    }
}

#[axum::async_trait]
impl<T, S> axum::extract::FromRequest<S> for Bcs<T>
where
    T: serde::de::DeserializeOwned,
    S: Send + Sync,
{
    type Rejection = BcsRejection;

    async fn from_request(
        req: axum::http::Request<axum::body::Body>,
        state: &S,
    ) -> Result<Self, Self::Rejection> {
        if bcs_content_type(req.headers()) {
            let bytes = axum::body::Bytes::from_request(req, state)
                .await
                .map_err(BcsRejection::BytesRejection)?;
            bcs::from_bytes(&bytes)
                .map(Self)
                .map_err(BcsRejection::DeserializationError)
        } else {
            Err(BcsRejection::MissingBcsContentType)
        }
    }
}

fn bcs_content_type(headers: &HeaderMap) -> bool {
    let Some(ContentType(mime)) = ContentType::from_headers(headers) else {
        return false;
    };

    let is_bcs_content_type = mime.type_() == "application"
        && (mime.subtype() == "bcs" || mime.suffix().map_or(false, |name| name == "bcs"));

    is_bcs_content_type
}

pub enum BcsRejection {
    MissingBcsContentType,
    DeserializationError(bcs::Error),
    BytesRejection(axum::extract::rejection::BytesRejection),
}

impl axum::response::IntoResponse for BcsRejection {
    fn into_response(self) -> axum::response::Response {
        match self {
            BcsRejection::MissingBcsContentType => (
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "Expected request with `Content-Type: application/bcs`",
            )
                .into_response(),
            BcsRejection::DeserializationError(e) => (
                StatusCode::UNPROCESSABLE_ENTITY,
                format!("Failed to deserialize the BCS body into the target type: {e}"),
            )
                .into_response(),
            BcsRejection::BytesRejection(bytes_rejection) => bytes_rejection.into_response(),
        }
    }
}

pub async fn append_info_headers(
    State(state): State<RpcService>,
    response: Response,
) -> impl IntoResponse {
    let mut headers = HeaderMap::new();

    if let Ok(chain_id) = state.chain_id().to_string().try_into() {
        headers.insert(X_SUI_CHAIN_ID, chain_id);
    }

    if let Ok(chain) = state.chain_id().chain().as_str().try_into() {
        headers.insert(X_SUI_CHAIN, chain);
    }

    if let Ok(latest_checkpoint) = state.reader.inner().get_latest_checkpoint() {
        headers.insert(X_SUI_EPOCH, latest_checkpoint.epoch().into());
        headers.insert(
            X_SUI_CHECKPOINT_HEIGHT,
            latest_checkpoint.sequence_number.into(),
        );
        headers.insert(X_SUI_TIMESTAMP_MS, latest_checkpoint.timestamp_ms.into());
    }

    if let Ok(lowest_available_checkpoint) = state.reader.inner().get_lowest_available_checkpoint()
    {
        headers.insert(
            X_SUI_LOWEST_AVAILABLE_CHECKPOINT,
            lowest_available_checkpoint.into(),
        );
    }

    if let Ok(lowest_available_checkpoint_objects) = state
        .reader
        .inner()
        .get_lowest_available_checkpoint_objects()
    {
        headers.insert(
            X_SUI_LOWEST_AVAILABLE_CHECKPOINT_OBJECTS,
            lowest_available_checkpoint_objects.into(),
        );
    }

    (headers, response)
}