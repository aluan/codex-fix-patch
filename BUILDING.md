# Rebuilding the patched CLI

The bundled binary is built from the OpenAI Codex tag `rust-v0.144.2` with Rust `1.95.0` on Apple Silicon.

```bash
git clone --branch rust-v0.144.2 https://github.com/openai/codex.git
cd codex
git apply /path/to/patches/codex-0.144.2-hosted-imagegen.patch
cd codex-rs
cargo test -p codex-core actor_authorized_custom_provider_uses_hosted_image_generation
cargo build --release -p codex-cli
codesign --force --sign - target/release/codex
```

After rebuilding, replace `bin/codex`, calculate its SHA-256 with `shasum -a 256 bin/codex`, and update `PATCHED_BINARY_SHA256` in `install-codex-imagegen-patch.sh`.

The patch restores hosted image generation for custom providers, custom base URLs, or providers with an explicit `x-openai-actor-authorization` header. The built-in first-party OpenAI provider retains the upstream standalone Images API implementation.
