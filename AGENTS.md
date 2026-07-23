# AGENTS.md

## Scope

These instructions apply to the entire repository.

## Project Overview

GPTSwitch is a macOS 14+ menu-bar application written in SwiftUI. It runs a loopback-only native proxy that lets Codex use Responses API, OpenAI-compatible Chat Completions, and Anthropic Messages providers. The repository also contains a legacy Python image-generation proxy, installer scripts, and a static website.

## Repository Layout

- `App/`: macOS application source.
  - `Models/`: persisted and transport data types.
  - `Services/`: proxying, protocol bridges, storage, configuration, credentials, and skin lifecycle.
  - `Stores/AppModel.swift`: main-actor application state and orchestration.
  - `Views/`: SwiftUI views.
  - `Support/`: paths, logging, and process helpers.
  - `Resources/`: plist, assets, themes, pricing data, and notices.
- `AppTests/`: XCTest coverage for native code; keep test filenames aligned with the production type or service.
- `proxy/` and `tests/`: legacy Python proxy and unittest suite.
- `script/`: build, run, package, and asset-generation scripts.
- `docs/`: static website deployed by GitHub Pages.
- `project.yml`: XcodeGen project definition and source of truth.

## Build and Test

Requirements: Xcode 26+, XcodeGen, and Python 3.9+.

```bash
# Regenerate the ignored Xcode project after changing project.yml or source layout
xcodegen generate --spec project.yml --project .

# Build the macOS app without signing
xcodebuild build \
  -project CodexImageGenProxy.xcodeproj \
  -scheme CodexImageGenProxy \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO

# Run native unit tests
xcodebuild test \
  -project CodexImageGenProxy.xcodeproj \
  -scheme CodexImageGenProxy \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO

# Validate the legacy Python fallback
python3 -m py_compile proxy/codex_imagegen_proxy.py tests/test_proxy.py
python3 -m unittest -v tests.test_proxy

# Validate installer syntax
bash -n install-codex-imagegen-patch.sh
```

Use `./script/build_and_run.sh --verify` only when launching a GUI app is appropriate. Use `./script/package_app.sh` only for release packaging; it recreates `.build/ReleaseDerivedData` and `dist/app`.

## Generated and Release Files

- Do not edit or commit `CodexImageGenProxy.xcodeproj`; regenerate it from `project.yml`.
- Do not commit `.build/`, `dist/`, Python bytecode, or other ignored outputs.
- Keep version and build values synchronized between `project.yml` and `App/Resources/Info.plist`.
- When changing bundled themes or third-party assets, update the relevant provenance and notice files.

## Swift Conventions

- Follow the existing Swift style: four-space indentation, one primary type per file, descriptive names, and minimal comments.
- Keep UI state and UI-facing mutations on `@MainActor`; prefer structured concurrency and preserve `Sendable` boundaries.
- Keep views declarative. Put networking, persistence, configuration editing, and protocol translation in services rather than SwiftUI views.
- Preserve explicit error handling and localized user-facing messages. Existing UI copy is primarily Simplified Chinese.
- Prefer small protocol adapters and typed request/event models over loosely typed dictionaries except at unavoidable JSON boundaries.
- Add or update focused XCTest coverage for behavior changes, especially protocol conversion, persistence migrations, configuration restoration, and malformed upstream data.

## Safety and Compatibility

- Keep proxy listeners bound to `127.0.0.1`; never broaden them to LAN or public interfaces without explicit approval.
- Never persist or log API keys, authorization headers, prompts, response bodies, thinking signatures, or tool arguments.
- Store credentials through `CredentialStore`/Keychain paths and preserve passthrough credential behavior.
- Treat edits to `~/.codex/config.toml`, model catalogs, caches, and backups as transactional: preserve backup and restore behavior on stop, failure, and migration.
- Protocol bridges must reject malformed payloads and unsupported tools explicitly; do not silently drop tool calls, tool results, SSE errors, or model identifiers.
- Preserve legacy state and envelope compatibility unless a migration and regression tests are included.

## Protocol Bridge Notes

- **`additional_tools` input items must be parsed, not dropped.** Codex CLI can deliver the tool catalog inside an `input` item of type `additional_tools` (role `developer`, with a `tools` array) instead of the top-level `tools` field. `ResponsesRequestParser.parse` extracts these, merges them into the tool catalog (skipping duplicate wire names), and filters the item out of `input` so it is not sent as a message. Forgetting this silently produces `tools: null` upstream, which makes models emit tool calls as XML text or loop.
- **Leaked tool calls in text are recovered by `XMLToolCallExtractor`.** Some upstream models (notably GLM-5.2) intermittently write tool calls as text instead of native `tool_use`: Cline/AntML `<function_calls><invoke name="functions.X"><parameter name="P">V</parameter></invoke></function_calls>`, `<tool_use><name>X</name><arguments>…</arguments></tool_use>`, JSON-in-wrapper, or flat `<X><p>…</p></X>`. The extractor sits between the protocol decoder and `ResponsesEventBridge` (both streaming and non-streaming) and converts these to native `function_call` events only when the tag/inner name matches the current tool catalog (after stripping `functions.`/`antml:` prefixes; looked up by both wire name and original name). Unknown tags and `<` in code pass through untouched. Conversion is a safety net; the real fix is making sure the catalog reaches the model.
- **GLM-5.2 repetition is upstream, not proxy-side.** When GLM-5.2 degenerates into repeating the same sentence, the repetition is already in the raw upstream stream before any bridge code touches it. It is intermittent and not reproducible by replaying the same request. Do not chase it in request construction; a repetition guard (abort looping streams) is the only proxy-side mitigation.
- **`tool_choice: required` maps to Anthropic `any`, which some relays reject.** claude-opus-4-8, kimi-k3, and GLM-5.2 accept `{type: any}`; qwen3.7-max (500) and deepseek-v4-pro (400) reject it. Codex CLI sends `auto` in normal use, so this only surfaces if a client sends `required`. The mapping is intentionally kept as `any` for correct semantics.
- **Diagnostic dumps** under `~/Library/Logs/CodexImageGenProxy/diag/` capture the incoming Codex request, the upstream request body, the raw upstream response, and the converted output per request (`incoming-latest.log`, `diag-latest.log`). They are debug-only and write per request; disable before release.

## Change Discipline

- Keep changes focused and do not rewrite unrelated code or user modifications.
- Test the narrowest affected area first, then run the full relevant Swift or Python suite.
- Update `README.md` when user-visible behavior, setup, limitations, or release commands change.
- Do not commit, push, publish packages, or modify a user's live Codex configuration unless explicitly requested.
