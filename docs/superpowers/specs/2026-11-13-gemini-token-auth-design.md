# Gemini token-only authentication

## Intent

Remove Google AI Studio / Gemini API-key authentication from kimo's Gemini provider. Use OAuth bearer access tokens everywhere, then validate the token and register the resulting live models in Kimi Code only when validation succeeds.

## Goals

- Accept `GEMINI_AUTH_TOKEN` and `GOOGLE_OAUTH_TOKEN`, plus the existing Gemini/Antigravity OAuth credential files.
- Preserve automatic refresh and atomic, owner-only credential writes.
- Send every real Gemini API request with `Authorization: Bearer`; never use `x-goog-api-key` for the Gemini provider.
- Always configure Kimi's Gemini provider with `api_key_env = "GEMINI_AUTH_TOKEN"`; never persist a token or API key.
- Reject legacy API-key options and API-key environment variables as Gemini credentials.
- Validate with headless regression tests, syntax/lint checks, and a live bearer-token catalog/model request before changing the user's Kimi config.

## Non-goals and constraints

- Do not add an OAuth login flow or change other providers.
- Do not remove agy's `GEMINI_API_KEY` localhost-shim session key. It authenticates agy to a local relay and is not a Google credential.
- Preserve unrelated uncommitted work and unrelated Kimi configuration.
- Offline fixture-based sync remains available for tests, but production live sync must not silently replace a failed/unauthorized catalog response with static models.

## Approaches

1. **Token-only throughout the Gemini provider (selected).** Remove API-key resolution, flags, header selection, and config branches from the helper, launch paths, quota adapter, tests, and documentation. This directly implements the requested behavior and leaves one unambiguous credential type.
2. **Keep API keys as a compatibility fallback.** Lower implementation cost, but violates the explicit removal request and preserves two authentication paths.
3. **Introduce a generic credential abstraction.** Could reduce duplication across providers, but is unnecessarily broad for this focused change and risks unrelated regressions.

The user's explicit token-only requirement selects approach 1; auto mode leaves no open design question requiring interaction.

## Implementation shape

Use the existing OAuth resolver/refresher as the sole source of Gemini access tokens. Rename internal Gemini key-oriented helpers where that clarifies the bearer-only contract. Keep environment-variable references in generated TOML, and remove stale inline `api_key` values when managed provider blocks are regenerated. Update tests to prove API keys are ignored, bearer headers are used, no raw token reaches configuration, and expired sessions still refresh.

## Verification and rollout

Run the focused Gemini, token-provider, launch-provider, quota, and backup tests, then the project's standard syntax/lint checks. Refresh the existing OAuth session, fetch `/v1beta/models` with bearer auth, and probe a small live generation. If those succeed, run the normal verified sync into `~/.kimi-code/config.toml`, validate the resulting TOML with Kimi, and confirm the registered aliases and provider credential reference. If live validation fails, leave the user's Kimi config unchanged and report the failure.
