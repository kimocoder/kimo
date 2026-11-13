# Gemini Token-Only Authentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Gemini / Google AI Studio access OAuth-bearer-only, validate it with automated and live checks, and populate validated models in Kimi Code.

**Architecture:** Keep the existing Gemini OAuth file resolver and refresh flow, but remove every Google API-key credential branch. The shell command and Python helper both resolve the same token, use bearer-only HTTP helpers, and write only `api_key_env = "GEMINI_AUTH_TOKEN"` into Kimi configuration.

**Tech Stack:** Bash, Python 3 standard library, jq, curl, tomlkit, existing shell/Python test harnesses.

**Spec:** `docs/superpowers/specs/2026-11-13-gemini-token-auth-design.md`

## Global Constraints

- Gemini credentials come only from `GEMINI_AUTH_TOKEN`, `GOOGLE_OAUTH_TOKEN`, or supported OAuth files.
- Real Gemini requests always use `Authorization: Bearer`; never `x-goog-api-key`.
- Never persist raw credentials; generated provider config always references `GEMINI_AUTH_TOKEN`.
- Preserve agy's unrelated `GEMINI_API_KEY` localhost-shim session key.
- Preserve unrelated uncommitted edits and Kimi config; no commits unless explicitly requested.
- Do not populate the user's Kimi config unless live bearer validation succeeds.

## Review Focus

- Legacy `GEMINI_API_KEY` / `GOOGLE_API_KEY` values must not silently authenticate a Gemini launch; test rejection in Task 2.
- Expired stored OAuth sessions must still refresh before use; retain and extend the existing refresh test in Task 1.
- Offline fixture sync must not require network access or write a raw token; test fixture sync in Task 1.
- Failed live catalog fetches must not fall back to a static list and appear validated; test error propagation in Task 1.
- Generated config must remove stale inline Gemini credentials and pass Kimi's parser; test managed-block regeneration in Task 2.

---

### Task 1: Bearer-only Gemini helper

**Files:**
- Modify: `lib/kimo-gemini.py`
- Test: `tests/token_providers_test.sh`

**Interfaces:**
- `get_working_token(home: Path) -> str` returns only an OAuth access token.
- `fetch_live_models(token: str, timeout: float = 6)` sends bearer auth and propagates HTTP/network/schema failures instead of returning `GEMINI_MODELS` after a failed request.
- `sync(...)` continues to write Gemini aliases, always with `api_key_env = "GEMINI_AUTH_TOKEN"`.

- [ ] **Step 1: Add failing regression assertions**

In the Gemini section of `tests/token_providers_test.sh`, assert that API-key-only environment input yields `missing` / a failed token command, that OAuth status/export contain no API-key variables, and that sync writes only the bearer environment reference. Add a local HTTP models endpoint test proving the helper sends `Authorization: Bearer` and returns a nonzero status on 401 rather than a static fallback.

- [ ] **Step 2: Run the focused test and confirm the new assertions fail**

Run: `make test-token-providers`
Expected: existing OAuth tests pass; new API-key-removal or failed-fetch assertions fail.

- [ ] **Step 3: Implement token-only helper behavior**

Remove API-key environment resolution, token-in-key-variable coercion, API-key status fields/branches, and AIza header/export/config selection. Update errors to name `GEMINI_AUTH_TOKEN` / `GOOGLE_OAUTH_TOKEN` or `agy`. Make `fetch_live_models` return parsed models on success and raise a descriptive `ValueError` on failure; retain static models only for the explicit empty-token offline path if needed by existing callers.

- [ ] **Step 4: Run the focused tests**

Run: `make test-token-providers && make test-gemini`
Expected: token-provider tests pass; Gemini fixture tests may still fail until Task 2 updates their obsolete API-key options.

### Task 2: Bearer-only command, launch, quota, and config paths

**Files:**
- Modify: `kimo` (`_resolve_gemini_auth`, `_ensure_gemini_token`, Gemini launch setup, `_gemini_*`, quota credential resolver)
- Modify: `lib/kimo-quota.py`
- Modify: `lib/kimo-anthropic-proxy.py` (remove Google API-key header selection only)
- Test: `tests/gemini-smoke.sh`
- Test: `tests/token_providers_test.sh`
- Test: `tests/codex_providers_test.sh`
- Test: `tests/claude_providers_test.sh`
- Test: `tests/quota_adapters_test.py`
- Test: `tests/backup_prune_test.sh`

**Interfaces:**
- `_gemini_curl_bearer TOKEN CURL_ARGS...` sends only `Authorization: Bearer` via curl stdin config.
- `_gemini_resolve_token` resolves explicit token environment/files and rejects API-key-only input.
- Gemini sync accepts no `--api-key` or `--api-key-env` options; its managed provider block always uses `GEMINI_AUTH_TOKEN`.

- [ ] **Step 1: Replace API-key fixtures with failing bearer-only contract tests**

Use OAuth fixture tokens in all Gemini launch/sync tests. Add assertions that `--api-key` and `--api-key-env` are rejected, `GEMINI_API_KEY=AIza...` cannot launch or sync, no `x-goog-api-key` is emitted by the Gemini provider paths, and regenerated config contains neither `api_key =` nor a raw fixture token. Update backup tests to pass an OAuth environment token. Update quota tests to assert bearer-only headers and unconfigured status for API-key-only input.

- [ ] **Step 2: Run focused tests and confirm obsolete behavior is exposed**

Run: `make test-gemini test-token-providers test-codex-providers test-claude-providers test-quota test-backup-prune`
Expected: failures on remaining API-key acceptance, header branching, or obsolete options.

- [ ] **Step 3: Implement shell and quota token-only flow**

Remove key-oriented options/state and API-key environment fallbacks from Gemini command/sync/launch/quota resolution. Always mirror resolved OAuth tokens into `GEMINI_AUTH_TOKEN` / `GOOGLE_OAUTH_TOKEN`, select only those variables for launches, validate token syntax without accepting AIza keys, and send bearer headers. Keep agy's local shim session-key code unchanged. Remove inline `api_key` from regenerated Gemini provider blocks.

- [ ] **Step 4: Run all focused tests**

Run: `make test-gemini test-token-providers test-codex-providers test-claude-providers test-quota test-backup-prune`
Expected: all pass.

### Task 3: Documentation, full checks, live validation, and Kimi rollout

**Files:**
- Modify: `README.md` Gemini sections and credential examples.
- Modify: `kimo` Gemini help/completion text.
- Modify user config only after validation: `~/.kimi-code/config.toml` through `kimo gemini` (automatic timestamped backup).

**Interfaces:**
- User-facing Gemini commands document OAuth token inspection/export/refresh and model sync only.

- [ ] **Step 1: Update stale documentation and help**

Replace Gemini API-key examples and descriptions with `GEMINI_AUTH_TOKEN` / `GOOGLE_OAUTH_TOKEN`, retaining other providers' API-key documentation and agy's local shim explanation.

- [ ] **Step 2: Run standard static checks and relevant suites**

Run: `make check && make lint && make test-gemini test-token-providers test-codex-providers test-claude-providers test-quota test-backup-prune`
Expected: all pass. If a pre-existing unrelated failure appears, identify it rather than changing unrelated code.

- [ ] **Step 3: Validate the real OAuth session without exposing secrets**

Run `kimo gemini --token` only through a non-printing pipeline/subprocess that consumes the token. Refresh if necessary, require a successful bearer `GET /v1beta/models`, and make one minimal `generateContent` request to a listed chat model. Record only HTTP/result status and model names, never token material.

- [ ] **Step 4: Populate and validate Kimi configuration**

If Step 3 succeeds, run `./kimo gemini --verify --verify-prune` against the real config. Validate with `kimi doctor config ~/.kimi-code/config.toml` and confirm `[providers.gemini]`, `api_key_env = "GEMINI_AUTH_TOKEN"`, and the verified `gemini/*` aliases. If live validation fails, do not run the config-writing step.

- [ ] **Step 5: Inspect final workspace state**

Run: `git status --short`
Expected: only intended source/test/doc changes plus pre-existing edits; remove any temporary files created inside the repo by verification.
