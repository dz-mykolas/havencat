#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();

    // Initialize the tracing subscriber so that `tracing::warn!`/`error!`/etc.
    // in the Rust web_retrieval module actually produce output. Controlled by
    // the standard `RUST_LOG` env var (e.g. `RUST_LOG=debug`,
    // `RUST_LOG=web_retrieval=trace`). Defaults to `info` if unset.
    // Safe to call multiple times — only the first call installs a subscriber.
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .try_init();
}
