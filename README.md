# kimo

**Unified Local & Remote Model Management & External CLI Hub**

`kimo` is an advanced command-line tool designed for managing Ollama instances across local and remote environments, inspecting GPU VRAM residency, tuning execution parameters, and routing external LLM agent CLIs (`claude`, `codex`, `qwen`, `grok`, `kimi`, `cursor`, `agy`, `hermes`, `openclaw`) directly into your self-hosted models.

---

## Features

- **Multi-Host Routing**: Seamlessly query or execute against local daemons and remote GPU servers over SSH tunnels or direct LAN connections.
- **Network Discovery & LAN Scanning**: Fast, multithreaded network discovery tool (`scan` / `discover`) identifying active Ollama instances across local subnets, IP ranges, or CIDR blocks with deep model catalog and VRAM residency inspection.
- **Real-Time VRAM Monitor**: Live interactive GPU/CPU residency monitor (`top` / `ps --watch`) tracking memory usage across cluster hosts.
- **Cluster Model Replication**: One-click bidirectional synchronization and digest verification across cluster hosts (`sync`).
- **Streaming Model Benchmarking**: True time-to-first-token (TTFT) profiling, generation throughput (tok/s), memory residency, and structured JSON output (`bench`).
- **Streaming Model Pulling**: Pull models directly from Ollama registries with live multi-layer download progress, layer digests, transfer speeds, and status updates (`pull`).
- **Model Tuning & Persistence**: Bake per-model parameters (`num_ctx`, `num_batch`, `num_predict`, `temperature`, `num_gpu`) into runtime launches without modifying raw Modelfiles.
- **Streaming & Keepalive Pinning**: Durable model availability via background keepalive and pre-warming (`stream`).
- **Shell Autocompletion**: Comprehensive tab completion scripts for Bash and Zsh covering commands, flags, CLIs, config options, and dynamic model names (`completion`).
- **External CLI Hub**: Automatic model mapping, endpoint rewriting, context-window patching, and wire-format translation for:
  - **Claude Code CLI** (`claude`)
  - **Codex CLI** (`codex`)
  - **Qwen Code CLI** (`qwen`)
  - **Grok Build CLI** (`grok`)
  - **Kimi Code CLI** (`kimi`)
  - **Cursor CLI** (`cursor` / Cursor Agent)
  - **Google Antigravity CLI** (`agy`)
  - **Cyberstrike AI Pentesting CLI** (`cyberstrike`)
  - **Hermes / OpenClaw**
- **Hosted Cloud Provider**: `launch --provider abliteration` routes `claude` and `kimi` at the [abliteration.ai](https://docs.abliteration.ai) Anthropic-/OpenAI-compatible API instead of a self-hosted Ollama daemon — no host probing, no model eviction, and the API key stays in the environment only. For `kimi`, a validated key registers a named `[providers.abliteration]` (credential by env-var reference) plus every model the API serves.
- **DashScope (Alibaba Model Studio)**: `launch --provider dashscope` routes `kimi`, `claude`, `codex` and `agy` at Model Studio — the key's class picks the surface (`sk-ws-`/`sk-` → pay-as-you-go intl, `sk-sp-` → token-plan); kimi rides a zero-footprint env channel, claude the Anthropic-compatible `/apps/anthropic` endpoint, codex the Responses wire, and agy the loopback Gemini shim in its OpenAI-compatible mode (Model Studio exposes no Gemini endpoint). With no env key kimi falls back to the freetier-managed `alibaba/` aliases.
- **Alibaba Free Tier**: `launch --provider alibaba` explicitly targets the freetier-managed `[providers.alibaba]` configuration in Kimi Code CLI with a default context size of 500,000 tokens (preventing continuous context auto-compaction loops with DeepSeek models).
- **vLLM (self-hosted OpenAI server)**: `launch --provider vllm` routes `kimi` and `claude` at a local or remote vLLM server (default `http://127.0.0.1:8000/v1`). Without a configured base it also probes `http://127.0.0.1:18000/v1` (a common `ssh -L` forward), the configured remote host, the GPU box at `192.168.1.104` on ports 8000 and 18000, and `KIMO_VLLM_BASE_URLS`, and without `--model` it lists `GET /v1/models` and launches the first chat model, skipping embedding/reranker ids. It is not an Ollama daemon: no `/api/tags`, no VRAM eviction, no tune registry. A reachable `GET /v1/models` registers `[providers.vllm]` (or `vllm-<host>`) and one alias per served model. `VLLM_API_KEY` is stored by env-var name only. When that variable is unset, kimo reads `$KIMO_VLLM_API_KEY_FILE`, or `$HOME/vllm/api.key` for a loopback server, or `~/vllm/api.key` of the account that is listening with `vllm` (root's own home has no key). The file must be mode `0600`, not a symlink, and not other-writable. The `/v1/models` probe bypasses `http_proxy` and `all_proxy`. With no key the placeholder is `EMPTY`. A 401 from the default port with no key does not hide a later candidate. Unrelated credentials are still scrubbed when the server is not on this machine.

---

## Installation & Setup

Clone the repository and install using `make`:

```bash
# System-wide installation to /usr/local/bin/kimo (default)
sudo make install

# Install shell tab-completions for Bash and Zsh
sudo make install-completion

# Or create a live development symlink:
sudo make link

# Verify syntax & execution sanity
make check
```

### Makefile Targets

| Target | Description |
|---|---|
| `make install` | Installs `kimo` to `$(DESTDIR)$(BINDIR)/kimo` (default `/usr/local/bin/kimo`) with executable permissions |
| `make uninstall` | Removes installed `kimo` binary from `$(DESTDIR)$(BINDIR)` |
| `make link` | Creates development symlink from repo directly to `$(BINDIR)/kimo` |
| `make unlink` | Removes the development symlink |
| `make install-completion` | Installs shell autocompletion for Bash (`/etc/bash_completion.d/kimo`) and Zsh |
| `make uninstall-completion`| Removes installed completion scripts |
| `make check` | Validates bash syntax (`bash -n`) and executes basic CLI sanity tests |
| `make lint` | Runs `shellcheck` with error filtering on `kimo` |
| `make test` | Runs the full test suite across all headless smoke test targets |
| `make test-check` | Headless smoke test of `kimo check` and `kimo ping` connectivity diagnostics |
| `make test-web` | Headless smoke test of WebBridge browser relay and web research (`kimo web`) |
| `make test-scan` | Headless smoke test of network scanning, discovery, and first-run wizard |
| `make test-gh` | Headless smoke test of GitHub CLI (`gh`) integration contracts and update safety |
| `make test-qwen` | Headless smoke test of the `qwen` launch branch: asserts the argv/env kimo passes (api-key scrubbing, `QWEN_CODE_API_TIMEOUT_MS`). Add `LIVE=1` for an opt-in live `-p` turn against a reachable Ollama host (`KIMO_SMOKE_HOST`/`KIMO_SMOKE_MODEL` override) |
| `make test-claude` | Headless smoke test of the `claude` launch branch: asserts the env kimo passes (api-key scrubbing, `CLAUDE_CODE_*` defaults incl. unknown-model window enforcement and telemetry/MCP flags with user overrides honoured, `--ctx` → `OLLAMA_CONTEXT_LENGTH`, `API_TIMEOUT_MS` passthrough). Add `LIVE=1` for an opt-in live `-p` turn |
| `make test-agy` | Headless smoke test of the `agy` launch branch: asserts shim liveness/reaping, settings patch + restore, and that `GEMINI_API_KEY` is never scrubbed (it is the shim's own session key, not a provider credential, and only reaches the loopback shim). Add `LIVE=1` for an opt-in live `-p` turn |
| `make test-opencode` | Headless smoke test of the `opencode` launch branch: asserts the argv/env kimo passes (host env, `OPENAI_API_KEY`/`ANTHROPIC_API_KEY` scrub for non-local hosts). opencode routes via its own provider config and reads no base-url env, so the scrub is defence-in-depth. Add `LIVE=1` for an opt-in live `run` turn against an isolated `HOME` with a throwaway provider (`KIMO_SMOKE_HOST`/`KIMO_SMOKE_MODEL` override) |
| `make test-codex` | Headless smoke test of the `codex` launch branch: asserts the argv/env kimo passes (`--oss`, `--local-provider ollama`, `CODEX_OSS_BASE_URL` host routing, `OPENAI_API_KEY` default). Add `LIVE=1` for an opt-in live `exec` turn against a reachable Ollama host (`KIMO_SMOKE_HOST`/`KIMO_SMOKE_MODEL` override) |
| `make test-codex-auth` | Isolated Codex native command forwarding, cloud/Ollama precedence, credentials, and Kimi model sync with backups |
| `make test-cursor` | Headless smoke test of the `cursor` launch branch: asserts the argv/env kimo passes (`--model`, `CURSOR_MODEL`, `CURSOR_API_ENDPOINT`/`CURSOR_API_BASE_URL`/`CURSOR_LOCAL_AGENT_BASE_URL` host routing, override handling) and the `cursor` → `cursor-agent` binary fallback. Add `LIVE=1` for an opt-in live `-p` turn against a reachable Ollama host (`KIMO_SMOKE_HOST`/`KIMO_SMOKE_MODEL` override) |
| `make test-grok` | Headless smoke test of the `grok` launch branch: asserts the argv/env kimo passes (`--model`, `GROK_MODELS_BASE_URL` host routing, forced `XAI_API_KEY` scrub for all hosts, exit-code propagation) and the `--ctx` config.toml `context_window` patch/revert lifecycle. Add `LIVE=1` for an opt-in live `-p` turn against a reachable Ollama host (`KIMO_SMOKE_HOST`/`KIMO_SMOKE_MODEL` override) |
| `make test-thinking-tools` | Checks the thinking/tools capability handling: `_kimi_model_spec` unit checks (capability mapping `thinking`/`tools`/`vision` → `thinking`/`tool_use`/`image_in`, probe-failure fallback to `tool_use`, override precedence, ctx precedence flag > runtime > architecture) plus launch-branch integration (kimi env channel exports thinking vars only for thinking models, scrubs stale inherited effort on non-thinking models, honours `KIMO_KIMI_EFFORT`/`KIMO_KIMI_REASONING_KEY`/`KIMO_KIMI_CAPABILITIES`) |
| `make test-gemini` | Headless smoke test of `kimo gemini` model sync into Kimi Code: asserts `/v1beta/models` parsing, non-chat filtering, `--stable-only`/`--all` flags, token limits mapping, thinking capability, valid TOML generation, idempotency, and backup creation |
| `make test-abliteration` | Headless smoke test of the abliteration.ai cloud provider (`launch --provider abliteration`): base-URL routing for both API surfaces, the forwarded key never reaching argv, console or config, Claude's `[1m]` context suffix and tier overrides, kimi's validated `[providers.abliteration]` config path (served-catalogue registration, `api_key_env` reference, `ABLIT_KEY` normalization, 401 abort) and its zero-footprint env-channel fallback, per-model capabilities/effort ceilings, provider precedence (flag > env > config), and the absence of any Ollama probing |
| `make test-dashscope` | Headless smoke test of the DashScope cloud provider (`launch --provider dashscope`): intl compatible-mode routing, default/explicit/`--ctx` model selection, `DASHSCOPE_API_KEY` with `MODELSTUDIO_API_KEY` fallback, placeholder and missing-key rejection, kimi's zero-footprint `KIMI_MODEL_*` env channel (wire type, base URL, context, reasoning key), provider precedence, remote-host key scrubbing, the absence of any Ollama probing, and agy's Gemini→OpenAI shim turn (a real translated request reaches `/chat/completions` with the key as a bearer token, while agy's own environment never sees that key) |
| `make test-vllm` | Headless smoke test of `launch kimi --provider vllm`: base-URL normalization, fallback endpoint discovery, served-model listing and auto-selection, catalogue registration from `/v1/models`, `EMPTY` vs `VLLM_API_KEY` by name, context capping, thinking-id detection, env-channel fallback, remote credential scrubbing, and no Ollama probe or `ollama run` fallback |
| `make test-quota` | Headless smoke test of unified quota & usage dashboard (`kimo quota`) |
| `make test-tunnel` | Headless smoke test of remote Ollama SSH tunnel management (`kimo tunnel`) |
| `make test-config-validate` | Headless smoke test of persistent configuration validation (`kimo config validate`) |
| `make test-rotate-token` | Headless smoke test of public API token rotation (`kimo rotate-token`) |
| `make test-jq-guard` | Headless smoke test of jq prerequisite guarding across CLI commands |
| `make test-pull-json` | Headless smoke test of streaming JSON output on model pulls (`kimo pull --json`) |
| `make test-backup-prune` | Headless smoke test of automatic backup rotation and pruning |
| `make test-web-url-esc` | Headless smoke test of WebBridge URL escaping and payload generation |
| `make test-gh-guard` | Headless smoke test of GitHub CLI (`gh`) management-only guard |
| `make test-launch-contract` | Launch contract for every CLI: credential scrub for non-local hosts, child-flag passthrough and `--`, opt-in `--evict` |
| `make test-sync` | Blob-level `sync` between two fake daemons (upload, create, weight verification, `--force`), plus the digest-verified registry fallback |
| `make test-model-commands` | Core model commands against fake local and remote daemons: `search` honors `--local`/`--remote` and reports VRAM residency per host; `stream` runs the shipped helper with kimo's remote resolution; `bench` TTFT includes cold loads, `--runs`/`--warmup` |
| `make test-shim` | Gemini shim contract against both upstream wires (Ollama `/api/chat` and OpenAI-compatible `/chat/completions`): `model:tag` paths, JSON-array/SSE streaming, mid-stream errors, tools, images, `countTokens`, request validation, and on the OpenAI side the top-level sampling controls, `response_format`, `enable_thinking`, reassembly of fragmented tool calls, `reasoning_content` → thought parts and bearer credential forwarding |
| `make test-install-packages` | Installers request only official npm/PyPI packages and never fall back to look-alike names |
| `make clean` | Removes temporary and backup files (`*~`, `*.tmp`, `*.bak`) |
| `make help` | Displays list of available make targets and options |

---

## Usage

```bash
kimo [options] <command> [arguments...]
```

### Global Options

| Option | Description |
|---|---|
| `--remote` | Connect to remote server (e.g., `http://127.0.0.1:11438` tunnel) |
| `--local` | Connect strictly to local daemon (`http://127.0.0.1:11434`) |
| `--host <address>` | Target specific Ollama host address (can be repeated for multi-host) |
| `--json` | Output responses in structured JSON format |
| `--no-color` | Disable colored terminal output |
| `-v, --version` | Show kimo version |
| `-h, --help` | Show help and usage information |

---

## Command Reference

| Command | Description | Example |
|---|---|---|
| `check`, `ping` | Connectivity, latency, and health check for local and remote hosts | `kimo check` |
| `hosts` | Detailed table of reachable servers, versions, models, disk GB | `kimo hosts` |
| `init [opts]` | Interactive initial setup & network discovery wizard | `kimo init` |
| `scan`, `discover [target]` | Discover active Ollama instances on LAN/subnets (`-i`, `-m`, `--save`) | `kimo scan -i` |
| `doctor` | All-in-one health diagnostics (system, tunnel, daemons, CLIs) | `kimo doctor` |
| `config [subcmd]` | View and manage persistent defaults in `~/.config/kimo/config` | `kimo config set default_host remote` |
| `status`, `health` | Operational snapshot: tunnel, remote API, VRAM residency, timer | `kimo status` |
| `list [filter]` | List all installed models across hosts, highlighting active VRAM | `kimo list nemotron` |
| `search <query>` | Search models across catalogs by name, parameters, capabilities | `kimo search 27b` |
| `ps` | Display models currently resident in GPU/CPU VRAM with memory stats | `kimo ps` |
| `top` | Interactive real-time VRAM residency monitor (`ps --watch`) | `kimo top` |
| `pull <model>` | Pull model from registry with live streaming progress & speed | `kimo pull llama3:latest` |
| `stop [model\|all]` | Unload models from VRAM immediately (`keep_alive: 0`) | `kimo stop all` |
| `warm <model> [dur]`| Pre-warm model into GPU VRAM (`keep_alive: 24h` by default) | `kimo warm kalidroid-27b` |
| `info <model>` | Inspect detailed model metadata, quant, template, parameters | `kimo info kalidroid-27b` |
| `tune <model> [opts]`| Register per-model defaults (`--ctx`, `--batch`, `--temp`, etc.) | `kimo tune model --ctx 32768` |
| `bench [model]` | Benchmark TTFT, generation throughput (tok/s), and memory | `kimo bench kalidroid-27b -n 30` |
| `sync <model>` | Replicate and synchronize models across cluster hosts | `kimo sync kalidroid-27b --to local` |
| `tag <src> <dst>` | Create model tag/alias on target host | `kimo tag model:33b model:latest` |
| `rm <model>... [-y]` | Delete one or more models (exact names; all are checked before any is deleted; asks first, `--yes` to skip) | `kimo rm old-a old-b` |
| `stream <model>` | Pin model for durable availability via keepalive daemon (helper: `lib/kimo-stream.py`, override with `KIMO_STREAM_HELPER`) | `kimo stream model --status` |
| `run <model> [args]`| Run model directly with auto-routing to remote GPU | `kimo run kalidroid-27b` |
| `launch <cli> [opts]`| Launch external CLI with automatic Ollama routing | `kimo launch grok --model 27b` |
| `install [cli\|all]` | Install/update external CLIs (`kimi`, `claude`, `grok`, `codex`, `qwen`, etc.) | `kimo install kimi` |
| `update [cli\|all]`  | Check for updates for all installed CLIs, or apply updates | `kimo update` |
| `completion [sh]`    | Generate shell tab-completion script for Bash or Zsh | `kimo completion bash` |
| `freetier [opts]`    | Sync Kimi config with Model Studio free-tier quotas (`bl usage free`) | `kimo freetier --verify-prune` |
| `gemini [opts]`      | Register Gemini API models into Kimi Code, inspect OAuth token & accounts | `kimo gemini --token` |
| `claude [opts\|cmd]` | Inspect Claude OAuth token, sync models into Kimi, or forward Claude CLI | `kimo claude --token` |
| `codex [opts\|command]` | Inspect Codex authentication, sync models into Kimi, or forward native Codex commands | `kimo codex login --device-auth` |
| `quota [cli] [opts]` | Check provider usage and every supported CLI account | `kimo quota codex --json` |
| `kimi provider [cmd]` | List, disable/enable, or sync Kimi Code's LLM providers and model aliases | `kimo kimi provider sync --prune` |

---

## Quota and Usage (`quota`)

`kimo quota` shows the existing Ollama, Gemini, Bailian, OpenRouter, and WebBridge checks alongside every supported CLI. `quotas` and `quote` are aliases. Python 3.11 or newer supports all adapters, including Kimi's TOML configuration; only the standard library is used.

```bash
kimo quota                         # Providers and all CLI accounts
kimo quota --cli all                # Installed CLI accounts with readable quotas only
kimo quota --cli all --show-all     # Also list CLIs that are missing or report no quota
kimo quota codex                    # One CLI
kimo quotas grok                    # Grok subscription credits and billing balances
kimo quotas kimi                    # Kimi Code windows and extra-usage wallet
kimo quotas kimi --no-refresh       # Use cached credentials without OAuth refresh
kimo quota claude --json            # Structured account windows and reset times
kimo quota claude --no-refresh      # Read Claude usage without rotating OAuth credentials
kimo quota --provider openrouter    # Existing provider filter
kimo quota --provider codex,grok,agy  # Account adapters work as providers; comma-separate or repeat
kimo quota --provider qwen --provider opencode
kimo quota --offline --json         # Installation checks without network or CLI execution
kimo quota --timeout 10             # Timeout budget per source (default 5s, maximum 60s)
kimo --host localhost:11434 quota --provider ollama
```

| CLI | Available quota check | Requirements and limits |
| --- | --- | --- |
| `codex` | Native `account/rateLimits/read` through app-server | Existing ChatGPT login; API-key accounts may not expose subscription windows. [Protocol](https://developers.openai.com/codex/app-server/) |
| `claude` | 5-hour, weekly/model-specific windows, reset times, plan, and extra-usage spending | Cached `.claude/.credentials.json`, `CLAUDE_CONFIG_DIR` / `CLAUDE_SECURESTORAGE_CONFIG_DIR`, or `CLAUDE_CODE_OAUTH_TOKEN`. Expiring cached logins refresh safely; usage requires the `user:profile` OAuth scope. API-key budgets are separate, and the private usage endpoint may change. [Authentication](https://code.claude.com/docs/en/authentication) |
| `kimi` | 5-hour, 7-day, monthly total/code windows, reset times, and extra-usage wallet/spending | Uses the configured global/mainland/custom API and scoped OAuth credentials, or `KIMI_CODE_API_KEY`. Refreshes expiring OAuth tokens safely. Only windows supplied by the account are shown; Moonshot API budgets are separate. [Official client](https://github.com/MoonshotAI/kimi-code) |
| `openclaw` | Native `status --usage --json` provider windows | Existing provider authentication. [Usage tracking](https://docs.openclaw.ai/concepts/usage-tracking) |
| `agy` | Google Code Assist per-model quota buckets | Cached Antigravity OAuth token; discovers the existing quota project or uses `GOOGLE_CLOUD_PROJECT` / `GOOGLE_CLOUD_PROJECT_ID`. These are Code Assist buckets, not a complete Antigravity subscription budget. |
| `cursor` | Team on-demand spend against enforced spending limits | Optional `CURSOR_ADMIN_API_KEY`; personal-plan usage remains in the dashboard. [Admin API](https://cursor.com/docs/account/teams/admin-api) |
| `qwen` | Bailian free-tier balances or configured OpenRouter budget | Qwen settings or provider environment; Bailian requires `bl` console login. Qwen OAuth daily remaining quota has no supported headless readout. |
| `opencode` | Selected provider's OpenRouter budget or configured Ollama status; OpenCode's own provider points at the Console | Reads local JSON/JSONC config and environment references; remote organization and managed overrides are not evaluated. OpenCode Console balance and monthly limits have no API, so `opencode/*` models report `unavailable` with Console guidance. |
| `hermes` | Configured OpenRouter budget, Ollama status, or local session usage | Provider environment / `.hermes/.env`; optionally set `HERMES_USAGE_FILE` to an existing `--usage-file` report. Local estimates are labelled separately. |
| `grok` | Native subscription credits, billing period, on-demand cap/spend, prepaid balance, plan, and billing history | Existing `grok login`; probes `_x.ai/billing` via `grok agent stdio`. Uses the native client's authentication/refresh. Older clients without billing support can fall back to a configured OpenRouter/Ollama backend. [Official billing protocol](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/extensions/billing.rs) |
| `cyberstrike` | Configured OpenRouter budget or Ollama status | Provider environment; otherwise guidance for checking the configured provider. |
| `gh` | Native GitHub API rate-limit resources | Existing `gh` authentication; these limits do not represent Copilot premium requests. |

`--provider` accepts the service providers above and any CLI account name (`codex`, `qwen`, `grok`, `agy`, `opencode`, ...); `all` cannot be mixed with other names. Account results stay under `clis` in JSON.

Every CLI remains visible even when it is missing, offline, unauthenticated, or cannot expose quota. Unsupported account checks return `unavailable` with instructions, rather than an invented balance. Ollama is marked `not_metered`; Gemini model token limits are labelled as context limits, with account quota unavailable. `--model` filters model-specific data while retaining account-wide windows.

JSON preserves the top-level `timestamp` and `providers` fields and adds `clis`. CLI entries include `installed`, `status`, `source`, `scope`, and `windows`; each window carries remaining/used amounts, percentages, units, and reset times when the source supplies them. Unknown values are `null`; exhausted balances remain zero. Account failures are isolated so other checks still complete, and dashboard exit status indicates command validity rather than whether every account was reachable.

Grok's JSON also includes `plan`, `billing`, and `history`; legacy monetary credit limits are supported when percentage usage is absent. Kimi adds `auth` (credential kind, refresh status, and region), `endpoint`, and `extra_usage`. Wallet fixed-point amounts are converted to currency; a disabled monthly spending cap does not imply a remaining allowance. Modern Kimi windows take precedence over duplicate legacy limits.

Claude includes `plan`, `rate_limit_tier`, `auth`, and `extra_usage`, preferring modern scoped `limits` over duplicate legacy windows. Extra-usage minor currency units are converted for display; disabled or unlimited spending limits do not invent a remaining allowance. Explicit `CLAUDE_CODE_OAUTH_TOKEN` values stay selected and are never replaced by another cached account.

Checks use existing authentication and never run a model turn. Expiring Claude/Kimi OAuth tokens, or a token rejected with HTTP 401, can be refreshed once and atomically saved with private permissions under the native client's refresh lock. Claude refresh also uses the native secure-storage write lock and preserves unrelated MCP credentials. `--no-refresh` disables these cached-token refreshes; native Grok/Codex commands use their own authentication handling. Account configuration is not edited. Credentials stay out of command arguments and output, and redirects are refused for direct API requests. `--offline` also skips credential-file reads. `KIMO_QUOTA_HOME` redirects adapter account-file discovery for isolated checks; `KIMI_CODE_HOME`, `KIMI_CONFIG`, `KIMI_CODE_BASE_URL`, `KIMI_CODE_OAUTH_HOST` / `KIMI_OAUTH_HOST`, and `GROK_HOME` follow their clients' account settings. Endpoint overrides select a matching Kimi credential slot rather than sending another region's token. `KIMO_QUOTA_HELPER` overrides the helper path for custom asset installations. `make install` installs the helper alongside the Gemini shim, and development symlinks locate it in the source checkout.

Run `make test-quota` for isolated dispatcher, account-adapter, and native protocol regression tests. Fixtures use temporary credentials and do not contact provider accounts.

## Health & Environment Diagnostics (`doctor`)

`kimo doctor` inspects your host dependencies, Ollama daemons, network tunnels, storage stores, and external CLI agents, producing a consolidated health scorecard with remediation steps:

```bash
# Run comprehensive diagnostic suite
kimo doctor
```

Checks performed:
1. **System Tools**: `curl`, `jq`, `python3`, `python3-tomlkit`, `node/npm`, and `systemd`.
2. **Configuration & Storage**: `~/.config/kimo/config`, `/var/lib/ollama/tunings.json`, and `/tmp` permissions.
3. **Local Daemon**: Reachability, version, API latency, installed catalog count, and active VRAM residency.
4. **Remote GPU & SSH Tunnel**: `ollama-remote-tunnel.service` state, tunnel endpoint latency, remote model catalog, and remote VRAM state.
5. **CLI Ecosystem**: Installation status, versions, and paths for all supported CLIs (claude, codex, qwen, grok, kimi, cursor, opencode, cyberstrike, agy, openclaw, hermes, gh).

---

## Server Health & Latency Probes (`check` / `ping`)

Quickly probe connectivity, latency, installed model counts, and active VRAM usage across local and remote instances:

```bash
# Check connectivity and latency across all configured nodes
kimo check

# Fast connectivity ping alias
kimo ping

# Probe strictly the local daemon
kimo --local check

# Route probe to a specific remote or custom host
kimo --host http://192.168.1.104:11434 check

# Output structured diagnostics in JSON format for automation/dashboards
kimo check --json
```

---

## Persistent Configuration (`config`)

`kimo` supports persistent user configuration stored at `~/.config/kimo/config` (or `/etc/kimo/config`), eliminating the need to re-supply flags or export environment variables for common workflows:

```bash
# View active configuration values and their sources (file, env, default)
kimo config

# Route all commands to the remote server by default
kimo config set default_host remote

# Set default model used when launching CLIs or native runs
kimo config set default_model kalidroid-27b:latest

# Set default thinking effort for Kimi Code CLI
kimo config set kimi_effort xhigh

# Set default context window for Kimi Code CLI (e.g. 256k tokens)
kimo config set kimi_context 262144

# Query a specific setting value
kimo config get default_host

# Remove a setting (revert to built-in default)
kimo config unset default_host

# Print the configuration file path
kimo config path
```

### Supported Configuration Keys

| Key | Description | Built-in Default |
|---|---|---|
| `default_host` | Default routing target (`local`, `remote`, or custom URL/address) | `auto (local+remote)` |
| `default_model` | Fallback model name for agent CLI launches | `kalidroid-27b:latest` |
| `remote_url` | Endpoint URL for the remote Ollama GPU host | `http://127.0.0.1:11438` |
| `local_url` | Endpoint URL for the local Ollama daemon | `http://127.0.0.1:11434` |
| `remote_host` | Remote host name or IP (no scheme/port) used for direct LAN probes | derived from `remote_url` or the SSH tunnel |
| `kimi_effort` | Default thinking effort for Kimi (`low`, `medium`, `high`, `xhigh`, `max`) | `default` |
| `kimi_context` | Default context window length in tokens for Kimi Code CLI | `auto` (model architecture/runtime) |
| `no_color` | Disable ANSI terminal color codes (`true`/`false`, `yes`/`no`, `1`/`0`); any non-empty `NO_COLOR` env var also disables color | `false` |
| `webbridge_url` | Endpoint URL for the Kimi WebBridge browser relay | `http://127.0.0.1:10086/command` |
| `webbridge_port` | Listening port for the Kimi WebBridge daemon | `10086` |
| `web_engine` | Search engine used for web research (`duckduckgo`, `bing`, `google`) | `duckduckgo` |
| `web_max_results` | Maximum link count extracted by web research helper snippets (1-999) | `10` |
| `cloud_provider` | Inference backend for `launch`: `ollama` (self-hosted) or `abliteration` (hosted API) | `ollama` |

Precedence is environment variable > config file > built-in default. `config set` and `config validate` apply the same per-key rules as the loader (values may not contain newlines or other control characters); an invalid value in the file is ignored with a warning instead of being applied.

---

## Free-Tier Quota Sync (`freetier`)

`kimo freetier` keeps the Kimi Code CLI pointed at the Model Studio (international) models that still have free-tier quota. It queries the free-quota console page through the Bailian CLI (`bl usage free --all --output json`, needs a live console login), filters to models with quota remaining, optionally live-probes each model, and rewrites the managed `[providers.alibaba]` + `[models."alibaba/..."]` block of `~/.kimi-code/config.toml` — a surgical edit with a timestamped backup first. Every other provider/model (kimo's `ollama-*` aliases, `managed:kimi-code`, `anthropic`, `alibaba-token-plan`, ...) is preserved. `default_model` is untouched unless you pass `--set-default`.

```bash
# Is the Model Studio console session live? (exit 0 live / 3 expired)
kimo freetier --check-auth

# Plan what would be written (writes nothing)
kimo freetier --dry-run

# Probe each candidate model, drop dead ones, then write config.toml
kimo freetier --verify --verify-prune

# Also make the top remaining-quota model the Kimi default
kimo freetier --set-default first

# Offline: reuse a previously saved quota dump
kimo freetier --from-json ~/quota.json --list-only
```

The console session (an API key alone cannot see free quotas) is refreshed with `bl auth login --console --console-site international`; `kimo freetier --check-auth` prints the full recipe, including the headless-host callback flow, when it has expired. The API key used for probing/writing is resolved from `--api-key`, `~/.qwen/settings.json`, `DASHSCOPE_API_KEY`, then the `bl` profile. `max_output_size` is capped at 65536 because the DashScope endpoint rejects larger `max_tokens`.

---

## OpenAI Codex CLI (`codex`)

Install, update, inspect, and run Codex through kimo:

```bash
kimo install codex
kimo update codex
kimo codex login                       # Native ChatGPT login
kimo codex login --device-auth         # Native device-code login
kimo codex login status
kimo codex exec --json "Review this repository"
kimo codex resume --last
kimo quota codex
```

`kimo codex <native-command> ...` forwards arguments, stdin, stdout, and exit status directly to Codex. This includes login/logout, exec, review, resume/fork, MCP, plugins, doctor, and completion. Native Codex handles authentication, credential storage, token refresh, profiles, and model selection. API-key login uses the native `login --with-api-key` stdin flow. See the [official Codex command reference](https://developers.openai.com/codex/cli/reference/).

`kimo codex` (or `status` / `--status`) shows an offline authentication snapshot with masked credentials; `--json` returns structured output. Use native `login status` to check accounts stored in the system credential store. `--token` explicitly prints the resolved ChatGPT OAuth bearer token, and `--export` emits a shell-quoted export for `CODEX_AUTH_TOKEN`.

Choose a launch backend explicitly:

```bash
kimo launch codex --provider codex                  # ChatGPT plan (OAuth), native model defaults
kimo launch codex --provider openai --model gpt-6.1-sol -- exec --json "Explain this repo"
kimo launch codex --provider ollama --model my-model --ctx 32768 -- exec "Explain this repo"
kimo --remote launch codex --provider ollama --model my-model
kimo launch codex --provider codex -c 'model_reasoning_effort="high"'
kimo launch codex --provider codex --dry-run
kimo launch codex --provider dashscope              # Responses wire, default qwen3.8-max
kimo launch codex --provider qwencloud --model qwen3-coder-plus
kimo launch codex --provider xai                    # alias: --provider grok
kimo launch codex --provider anthropic --dry-run
```

Ollama remains the default backend. OpenAI has two backends, and their credentials are not interchangeable:

| Backend | Endpoint | Credential | Billing |
| --- | --- | --- | --- |
| `--provider codex` | `https://chatgpt.com/backend-api/codex` | ChatGPT OAuth bearer token (`kimo codex login`) | Your ChatGPT plan |
| `--provider openai` | `https://api.openai.com` | Platform `sk-` key (`OPENAI_API_KEY` / `CODEX_API_KEY`) | Metered per token |

Both skip Ollama discovery/eviction and leave the model to Codex unless `--model` is supplied. A `codex/<model>` or `openai/<model>` alias selects the matching backend when no provider was chosen, as does an explicit credential: an OAuth login (or a renewable one) picks `codex`, a lone platform key picks `openai`. Native Codex also recognizes `CODEX_ACCESS_TOKEN`. An explicit provider always wins. Provider precedence is `--provider`, then `KIMO_CLOUD_PROVIDER`, then `cloud_provider` in kimo config. `-c` retains Codex's native config syntax; use `--ctx` for kimo's context override. Arguments after `--` pass through unchanged. Remote Ollama launches remove Codex bearer credentials, and dry-runs mask them.

One asymmetry to know about: **kimi** picks its credential from the provider entry kimo writes (`api_key_env`), so `--provider openai` always uses the platform key. The **Codex CLI** instead follows `auth.json`'s `auth_mode`, and a stored ChatGPT login wins over an exported `OPENAI_API_KEY` (verified against codex-cli 0.163.0). So `kimo launch codex --provider openai` warns that the session will bill your ChatGPT plan unless you store the key with `kimo codex login --with-api-key` or run `kimo codex logout` first.

The optional Kimi bridge works with either backend:

```bash
kimo codex --sync
kimo codex --set-default codex/gpt-6.1-sol
kimo launch kimi --provider codex                      # ChatGPT plan
kimo launch kimi --provider openai --model gpt-5.1-codex   # metered platform key
kimo launch kimi --model codex/gpt-6.1-sol
```

Sync reads the visible models, context sizes, input capabilities, and reasoning levels from `$CODEX_HOME/models_cache.json`; start Codex once to populate that catalog. Thinking models also get an `off_effort`, which kimi 2.x requires before it runs them with thinking switched off (prompt mode). The registered window is the catalog's `max_context_window` — the ceiling Codex allows for a `model_context_window` override — falling back to `context_window`; that keeps kimi's auto-compaction (90% of the window) from firing on the much smaller default. An explicit `--ctx` overrides it for the launched model, clamped to that ceiling. The Ollama-oriented `kimi_context` setting is not applied to a hosted window. It writes `[providers.codex]` (environment reference to `CODEX_AUTH_TOKEN`) or `[providers.openai]` (reference to `OPENAI_API_KEY`), plus `<backend>/<slug>` model aliases. An explicit `--model` is registered on its own, so the platform backend works on a box that never ran the Codex CLI. Launching Kimi syncs the selected model automatically. Existing comments and unrelated settings survive, changed files receive a backup, and concurrent writes use the Kimi config lock. `CODEX_HOME`, `KIMI_CODE_HOME`, and `KIMI_CONFIG` overrides are supported.

A ChatGPT access token expires after a few hours, so kimo renews it from `auth.json`'s `refresh_token` (the same call the Codex CLI makes) whenever `launch --provider codex`, `kimo codex --token` or `--export` needs a working credential. The renewed token is written back atomically at mode `0600` and is never printed or passed in argv; no plaintext backup of a credential file is left behind. Set `KIMO_CODEX_NO_REFRESH=1` to stay offline (`KIMO_CODEX_TOKEN_URL` / `KIMO_CODEX_REFRESH_TIMEOUT` override the endpoint and its timeout). `kimo codex` reports the refresh token and last renewal; `kimo codex --json` exposes `refreshable` and `last_refresh`. OpenAI Platform API keys cannot authenticate the ChatGPT endpoint — use `--provider openai` for those.

## Claude Code Authentication & Model Sync (`claude`)

`kimo claude` inspects Claude Code OAuth authentication (`~/.claude/.credentials.json`), manages tokens, and syncs Claude models into Kimi Code's configuration (`[providers.anthropic]`):

```bash
kimo claude                              # Inspect Claude OAuth session, expiration and plan
kimo claude --token                      # Print active Claude Code OAuth token
kimo claude --export                     # Output export statements for CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_AUTH_TOKEN
kimo claude --json                       # Structured JSON output
kimo claude --sync                       # Sync Claude models (claude-opus-5-5, etc.) into Kimi config
kimo claude --set-default                # Sync and set claude-opus-5-5 as default model in Kimi
kimo claude auth login                   # Native command forwarding directly to Claude CLI
```

## Google Gemini API Model Sync & Token Management (`gemini`)

`kimo gemini` inspects Google / Gemini CLI authentication (`~/.gemini/antigravity-cli/antigravity-oauth-token`), provides token export and automatic refresh, and registers Google Gemini API models directly into Kimi Code (`~/.kimi-code/config.toml`):

```bash
# Token & Authentication inspection
kimo gemini                              # Inspect Gemini account, OAuth expiration & credentials
kimo gemini --token                      # Output active OAuth bearer token or API key
kimo gemini --export                     # Output eval-able shell export statement
kimo gemini --json                       # Structured JSON authentication and model status

# Model synchronization
kimo gemini --verify --verify-prune      # Probe candidate models, prune failing, write config
kimo gemini --stable-only                # Register stable models only
kimo gemini --set-default gemini/gemini-2.5-flash
```

## Grok / xAI Token Management & Model Sync (`grok`)

`kimo grok` inspects Grok CLI authentication (`~/.grok/auth.json`), provides token export and auto-renewal, and syncs xAI models into Kimi Code (`~/.kimi-code/config.toml`):

```bash
kimo grok                                # Inspect Grok login session, account & expiration
kimo grok --token                        # Output active bearer token or API key
kimo grok --export                       # Output eval-able export for XAI_AUTH_TOKEN
kimo grok --json                         # Structured JSON session status
kimo grok sync                           # Sync xAI models (xai/grok-4.7, etc.) into Kimi config
kimo grok --set-default xai/grok-4.7     # Sync and set default model in Kimi
```

---

## Kimi Code Provider Management (`kimi provider`)

`kimo kimi provider` manages the `[providers.*]` blocks and `[models."<provider>/*"]` aliases in Kimi Code's `~/.kimi-code/config.toml` (`$KIMI_CONFIG` overrides the path). Every change is written atomically while holding kimo's Kimi config lock.

```bash
# Every provider, its type, alias count and whether it is enabled (* = default model's provider)
kimo kimi provider list

# Hide a provider from Kimi's /model picker without losing anything, then bring it back
kimo kimi provider disable groq
kimo kimi provider enable groq

# Check every provider's key against its /models endpoint and add the models it serves
kimo kimi provider sync
kimo kimi provider sync groq

# Preview, then remove aliases for models a provider no longer serves
kimo kimi provider sync --prune --dry-run
kimo kimi provider sync --prune

# Add OpenCode Zen (paid models) with your own key
OPENCODE_API_KEY=... kimo kimi provider sync opencode
```

**disable / enable.** Disable moves the provider block and every alias that belongs to it (by its `provider` field or a `<name>/` prefix) into `[disabled_providers]` and `[disabled_models]`. Kimi never reads those tables, but keeps them when it rewrites the file. If `default_model` pointed at the provider, it is cleared and remembered in `[disabled_defaults]`; enable puts the aliases back and restores that default, unless another default was chosen in the meantime. Running `enable` on an already enabled provider also recovers aliases an older kimo left hidden.

**sync.** For each provider kimo resolves the key (`api_key_env` or `api_key`), asks the provider's own `base_url` for its model list, and adds or refreshes `[models."<provider>/<model>"]` with display names and context/output limits. Keys only ever go to that `base_url`, in a header (`Authorization`, `x-api-key` or `x-goog-api-key`), and redirects are never followed. Provider types: `openai`, `anthropic` (`base_url` used as given, `/v1` added when missing), `google-genai`, and `openai_responses` (models from Codex's `models_cache.json`); Kimi-managed OAuth providers are skipped. Embedding, speech, image and moderation models are left out unless `--include-nonchat`.

| Option | Effect |
|---|---|
| `--all` | Sync every provider (the default when no name is given) |
| `--prune` | Remove aliases for models the provider no longer serves (never the current `default_model`) |
| `--dry-run` | Report what would change without writing |
| `--include-nonchat` | Keep embedding, speech, image and moderation models |
| `--timeout <s>` / `--jobs <n>` | Per-provider HTTP timeout (default 8) and parallel checks (default 4) |
| `--json` | Machine-readable results |

Statuses `ok`, `empty`, `skipped`, `no-credential`, `no-models-endpoint` and `no-cache` are informational. The command exits 1 only when a provider is actually broken: `bad-key`, `rate-limited`, `redirected`, `unreachable`, `http-error`, `parse-error` or `no-base-url`.

**OpenCode Zen.** `sync opencode` adds `[providers.opencode]` (`https://opencode.ai/inference/openai/v1`, key read from `$OPENCODE_API_KEY` and never written to the config; create one at https://opencode.ai/auth) once the key checks out. Only paid chat-completions models are aliased: free-tier models answer only the OpenCode client (kimi gets HTTP 403), and models on the `/responses` or `/messages` wire formats are skipped. Free and paid are told apart with models.dev pricing, from OpenCode's cache (`~/.cache/opencode/models.json`) or from https://models.dev when that cache is missing, has no Zen section, or lacks a model Zen serves. kimo warns when no price list is available, and names models it had to add without pricing.

---

## WebBridge & Quota-Free Research (`web`)

`kimo web` provides direct CLI control over Kimi's local WebBridge browser relay daemon (listening on `127.0.0.1:10086`), enabling quota-free research and real-browser page extraction with zero Moonshot token consumption.

```bash
# Probe WebBridge daemon reachability and active port/settings
kimo web status
kimo web status --json

# Execute web search through configured engine (DuckDuckGo, Bing, Google)
kimo web search "quantum error correction 2026"

# Open specific URL in the browser session
kimo web fetch https://docs.ollama.com

# Print a ready-to-paste curl navigation command for scripts
kimo web url https://news.ycombinator.com

# Launch Kimi Code CLI with automatic WebBridge skill injection (-W)
kimo launch kimi -W --model kalidroid-27b:latest
```

---

## CLI Package Manager (`install` & `update`)

`kimo` provides automated installation, updating, and health inspection for supported external CLIs, including GitHub CLI (`gh`, not Copilot).

Use `kimo install gh` for a fresh installation and `kimo update gh` (or `kimo install gh --update`) to update. GitHub CLI uses the latest official `cli/cli` release: Linux tar archives (amd64, arm64, 386, armv6) or macOS ZIP archives (amd64, arm64). Downloads are SHA-256 checked against the official release checksums, and the staged executable's version is verified before atomic replacement in `~/.local/bin/gh`. Add `~/.local/bin` to your shell's PATH if needed.

By default, updates and `--force` only replace an owned regular executable at that user-local path. For an existing standalone executable elsewhere in PATH, such as `/usr/local/bin/gh`, explicitly opt in with `kimo update gh --allow-system-path`. This flag is valid only for the named `gh` update (not `install`, other CLIs, or batches); adding `--check` reports eligibility and release status without writing files. A root-owned `/usr/local/bin/gh` is eligible when the current user is already root; kimo never invokes sudo.

Both paths require a writable regular executable and destination directory owned by the current user, with no symlinks anywhere in the destination path. Package-owned files, known package-manager stores, and failed ownership queries are refused; available `dpkg-query`, `rpm`, and `brew` are checked. Use the owning package manager (for example `brew upgrade gh`) or follow the [official installation guide](https://cli.github.com/manual/installation) for managed installations. No silent shadowing occurs. Replacement uses a unique attribute-preserving backup in the destination directory and a same-filesystem atomic rename. The installed absolute path's version is verified; a failed verification atomically restores the backup. Successful updates keep and report the backup path. `gh` appears in inventory, doctor, batch installation/updating and update checks, but has no Ollama model or `launch` integration.

```bash
# Display installed CLI inventory, versions, and paths
kimo install

# Install specific CLIs
kimo install kimi       # Installs Kimi Code CLI (code.kimi.com)
kimo install claude     # Installs Claude Code CLI (claude.ai)
kimo install grok       # Installs Grok Build CLI (x.ai)
kimo install codex      # Installs Codex CLI (npm)
kimo install qwen       # Installs Qwen Code CLI (npm)
kimo install cursor     # Installs Cursor CLI / Cursor Agent (cursor.com)
kimo install opencode   # Installs OpenCode CLI
kimo install cyberstrike # Installs Cyberstrike AI Pentesting CLI (cyberstrike.io)
kimo install openclaw   # Installs OpenClaw CLI
kimo install hermes     # Installs Hermes Agent CLI
kimo install agy        # Installs Google Antigravity CLI (official bootstrapper)

# Install or update all supported CLIs at once
kimo install all
```

### Checking for Updates Across Present CLIs

Running `kimo update` without arguments inspects only installed CLIs. Checks report **up to date**, **update available**, **ahead**, or **lookup failed/unknown**. Named and batch updates apply only confirmed newer releases; equal, locally newer, unreadable, and incompatible versions are skipped. Missing CLIs require `kimo install <name>`.

Numeric versions use semantic prerelease ordering and ignore build metadata. Cursor releases use valid dates; different opaque suffixes on the same date are unknown. Metadata checks are bounded, and failed lookups do not stop the batch. Apply summaries distinguish available releases, skips, attempts, verified upgrades, and failures; updater errors or an unverifiable installed-version change return nonzero.

```bash
# Check for updates across all installed CLIs (read-only audit)
kimo update
kimo update all --check

# Check one CLI without installing; flag order does not matter
kimo update qwen --check
kimo update --check qwen

# Update a specific installed CLI only when a newer release is confirmed
kimo update qwen
kimo update agy         # Uses agy's native self-updater (also: kimo install agy --update)

# Apply all available updates for currently installed CLIs
kimo update --apply     # or: kimo update all
```

`--check` and `--apply` cannot be combined. Unknown options and multiple targets are rejected.

---

## Real-Time VRAM & Model Monitor (`top` / `ps --watch`)

Monitor memory residency, active layers, and keepalive expiration in real time with an interactive top-like terminal dashboard:

```bash
# Launch real-time VRAM residency monitor (default 2s interval)
kimo top

# Specify custom refresh interval
kimo top -n 1

# Equivalent via ps watch flag
kimo ps --watch --interval 3
```

Features:
- Clean interactive redraws with terminal cursor preservation and graceful `Ctrl+C` handling.
- Live VRAM footprint (GB) and percentage of model resident in GPU VRAM vs CPU memory.
- Multi-host aggregation when queried across cluster nodes.

---

## Native Model Pulling with Live Streaming Progress (`pull`)

Pull models directly from Ollama registries with layer-by-layer progress bars, download speed (`MB/s`), and digest verification:

```bash
# Pull model to local Ollama daemon
kimo pull llama3:latest

# Pull model directly to remote GPU server
kimo --remote pull kalidroid-27b:latest

# Pull to an explicit cluster host
kimo --host 192.168.1.131:11434 pull qwen2.5:32b

# Insecure registry pull
kimo pull my-registry.internal/model:latest --insecure
```

---

## Cluster Model Replication (`sync`)

Replicate and synchronize models between local daemons and remote GPU servers with digest verification and directional auto-detection:

```bash
# Auto-detect direction and synchronize a model between local and remote
kimo sync llama3:latest

# Synchronize model from remote host to local daemon
kimo sync kalidroid-27b:latest --to local

# Synchronize model between custom host addresses
kimo sync qwen2.5:32b --from 192.168.1.131:11434 --to 127.0.0.1:11434

# Scan and synchronize all missing models from remote to local
kimo sync --all --from remote --to local

# Force re-synchronization even if the model exists on destination
kimo sync llama3:latest --force
```

Features:
- Automatic presence and digest comparison (`/api/tags`) before initiating transfer.
- Smart directional resolution: auto-detects which host has the model and replicates to the other.
- **True copies from a source on this machine**: Ollama's API can receive blobs but cannot serve them, so kimo reads the source model from a local model store (the manifest whose sha256 matches the digest the source daemon reports), uploads its weight/adapter/projector blobs to the destination (`POST /api/blobs`), recreates the model with its template, system prompt and parameters (`/api/create`), and verifies that the destination model references the same weights. Re-running reports identical weights instead of re-copying. Stores searched: `$KIMO_OLLAMA_MODELS` (colon-separated; exclusive when set), `$OLLAMA_MODELS`, `~/.ollama/models`, `/usr/share/ollama/.ollama/models`, `/var/lib/ollama/.ollama/models`.
- **Remote sources fall back to a registry pull on the destination**, which only succeeds if the resulting digest matches the source. A model that exists only on the remote host, or a registry build that differs from it, fails with an explanation instead of a false success. For an exact copy in that direction, run `kimo sync` on the source host.
- Conflict detection with actionable `--force` guidance when digests differ.

---

## Network Discovery & Instance Scanning (`scan` / `discover` / `init`)

`kimo scan` is a high-performance multithreaded network discovery tool designed to probe local physical interfaces, CIDR subnets, IP ranges, or specific endpoints to identify reachable Ollama instances, measure round-trip latency, inspect model catalogs, and report GPU VRAM residency.

`kimo init` provides an interactive setup wizard that scans your local network, presents reachable Ollama endpoints in a numbered selection menu, and writes the selected remote endpoint directly to persistent configuration (`~/.config/kimo/config`). On first run or when no remote configuration is present and the remote endpoint is unreachable, interactive commands will automatically offer to launch discovery.

```bash
# Interactive setup wizard: scan network and configure remote endpoint
kimo init

# Interactively discover and select which node to set as remote_url
kimo scan -i

# Auto-detect physical LAN subnet (e.g. 192.168.1.0/24) and loopback
kimo scan

# Deep model inspection: full model inventory, parameter counts, quantizations, and VRAM status
kimo scan -m

# Scan specific subnet with custom port
kimo scan 192.168.1.0/24 -p 11434

# Scan custom IP range
kimo scan 192.168.1.100-150

# Scan all common Ollama & reverse-proxy ports (11434-11438, 8000, 8080)
kimo scan --all-ports

# Automatically discover and save best remote node to persistent ~/.config/kimo/config
kimo scan --save

# Point remote_url directly to a discovered node
kimo scan --set-remote 192.168.1.104:11434

# Output discovery results in structured JSON format for automation and CI
kimo scan --json
```

### Options:

| Option | Description |
|---|---|
| `-p, --ports <ports>` | Comma-separated list of ports to scan (default: `11434,11438`) |
| `--all-ports` | Scan common Ollama and proxy ports (`11434-11438, 8000, 8080`) |
| `-t, --threads <num>` | Concurrency worker threads (default: `64`) |
| `--timeout <ms>` | Socket connection timeout in milliseconds (default: `400`) |
| `-m, --models, --deep` | Deep model inspection (model list, size, params, quant, VRAM residency) |
| `--all-interfaces` | Scan all interfaces including virtual container bridges (Docker, CNI) |
| `-i, --interactive` | Interactively select discovered instance to configure as `remote_url` |
| `--save` | Automatically save the best discovered remote node to `~/.config/kimo/config` |
| `--set-remote <endpoint>` | Set specified discovered endpoint as `remote_url` in config |
| `--json` | Output discovery results in structured JSON |
| `-h, --help` | Show scan help and usage information |

---

## Model Benchmarking & Performance Profiling (`bench`)

Benchmark inference throughput, time-to-first-token (TTFT), and VRAM residency:

```bash
# Benchmark model with default evaluation prompt (60 tokens)
kimo bench kalidroid-27b:latest

# Custom prompt and token generation limit
kimo bench kalidroid-27b:latest -p "Explain quantum computing in 3 sentences." -n 100

# Benchmark with sampling temperature override
kimo bench llama3:latest --temp 0.7 -n 50

# Output results in structured JSON for CI/automation pipelines
kimo bench kalidroid-27b:latest --json

# Run benchmark explicitly on remote GPU server
kimo --remote bench kalidroid-27b:latest -n 30

# Load the model first, then report min/median/max over 5 timed runs
kimo bench kalidroid-27b:latest --warmup --runs 5
```

With no model argument, `bench` uses `default_model` (`kimo config set default_model …`), then the model resident in VRAM, and otherwise exits with an error.

Metrics reported:
- **Time to First Token (TTFT)**: Client-measured time from sending the request to the first token, so it includes any model load, prefill and transport. Model load (`load_ms`) and prompt prefill are reported separately; a cold first run is flagged, and `--warmup` excludes it.
- **Runs**: `--runs N` repeats the measurement (each with a distinct first prompt line, so Ollama's prompt cache cannot shorten prefill) and reports medians with min/max; `--json` adds `stats` and per-run `results`.
- **Generation Speed**: Real-time streaming token throughput in tokens/sec (`tok/s`).
- **Prompt Speed**: Prompt evaluation speed in tokens/sec (`tok/s`).
- **Total Latency**: Wall-clock evaluation time.
- **VRAM Footprint**: Active GPU VRAM allocation during and after inference.

---

## Shell Autocompletions (`completion`)

`kimo` includes complete tab-completion for Bash and Zsh. It autocompletes commands, global flags, external CLIs, persistent configuration keys, and suggests installed Ollama models. Model suggestions come from a cached probe of the local daemon and the `127.0.0.1` tunnel (1s budget each, so a stalled remote never blocks a `<TAB>`); results refresh at most once per 30s and live in `~/.cache/kimo/models`:

```bash
# Load completion into active Bash session
source <(kimo completion bash)

# Install system-wide via Makefile (Bash + Zsh)
sudo make install-completion

# Manual system-wide installation for Bash
sudo kimo completion bash > /etc/bash_completion.d/kimo

# Zsh setup: save to your fpath directory
kimo completion zsh > ~/.zsh/completion/_kimo
```

---

## External CLI Hub (`launch`)

`kimo launch` wraps popular coding and conversational CLIs to redirect traffic to your target Ollama instance:

```bash
# Launch Claude Code on remote model. A real ANTHROPIC_API_KEY/AUTH_TOKEN is
# only forwarded to a plain local daemon; remote/LAN/tunnel hosts get 'ollama'
# so the secret never leaves this box.
kimo --remote launch claude --model nemotron3:33b

# Launch Kimi Code CLI with thinking model support. Registers the target host's
# whole model catalogue as aliases in ~/.kimi-code/config.toml, so kimi's
# /model picker lists every model - not just the one launched here.
kimo --remote launch kimi --model kalidroid-27b:latest

# Launch Grok Build TUI with tuned context
kimo --remote launch grok --model kalidroid-27b:latest

# Launch Qwen Code CLI (thinking + tools) routed to Ollama. A real
# OPENAI_API_KEY is only forwarded to a plain local daemon; remote/LAN/tunnel
# hosts get a placeholder ('ollama') so the token never leaves this box.
# QWEN_CODE_API_TIMEOUT_MS is raised to 600000 so large models do not trip
# qwen's 45s default on their first token.
kimo --remote launch qwen --model kalidroid-27b:latest

# Launch Google Antigravity CLI via automatic Gemini-to-Ollama wire shim
kimo launch agy --model kalidroid-27b:latest
kimo launch agy --provider dashscope            # same shim, OpenAI-compatible upstream

# Launch Cyberstrike AI pentesting agent routed to Ollama models
kimo launch cyberstrike --model kalidroid-27b:latest

# Launch Cursor CLI routed to Ollama models
kimo launch cursor --model kalidroid-27b:latest

# Pass flags straight to the CLI: after 'launch <cli>', -v/--version,
# -h/--help and --json belong to the CLI; everything after '--' is passed
# verbatim, even flags kimo itself knows (-m, --ctx, --evict)
kimo launch claude --model kalidroid-27b:latest -p "hi" -v
kimo launch qwen -- --version

# Free VRAM first by unloading the other models on the target host
kimo --remote launch claude --model nemotron3:33b --evict
```

Every launch applies the same credential rule: real `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` / `CURSOR_API_KEY` values reach only a plain local daemon, and any remote, LAN or tunnel host gets the `ollama` placeholder.

Other models already loaded on the target host are **not** unloaded unless you ask, because they may belong to other users or sessions sharing the GPU. On a terminal, kimo asks first (default: no). Non-interactive runs leave them loaded unless you pass `--evict` or set `KIMO_LAUNCH_EVICT=always`. Use `--no-evict` or `KIMO_LAUNCH_EVICT=never` to skip the question.

### Cloud Provider: DashScope (Alibaba Model Studio)

`--provider dashscope` routes a launch at Alibaba Model Studio. The credential's class picks the surface: `sk-ws-`/`sk-` keys go to the pay-as-you-go international endpoint (`https://dashscope-intl.aliyuncs.com/compatible-mode/v1`), `sk-sp-` token-plan keys to the subscription endpoint (`https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`) — each class 401s on the other's surface. It is wired for **`kimi`**, **`claude`**, **`codex`**, and **`agy`**; every other CLI stays on Ollama routing and errors out if you ask it to use the provider.

```bash
export DASHSCOPE_API_KEY="sk-..."        # MODELSTUDIO_API_KEY is accepted too

kimo launch kimi --provider dashscope                       # default: qwen3.8-max
kimo launch kimi --provider dashscope --model qwen3-coder-plus
kimo launch claude --provider dashscope                     # Anthropic wire, tier-mapped
kimo launch agy --provider dashscope                        # Gemini wire via the shim
kimo launch kimi --provider dashscope --ctx 131072 --dry-run

kimo config set cloud_provider dashscope                    # make it the default backend
```

kimi rides its zero-footprint `KIMI_MODEL_*` env channel (wire type `openai`, reasoning key `reasoning_content`, context 1,000,000 unless `--ctx` or `KIMO_DASHSCOPE_CTX` says otherwise), so nothing is written to kimi's config and the key never reaches argv or disk. claude rides each surface's Anthropic-compatible `/apps/anthropic` endpoint with the bearer in `ANTHROPIC_AUTH_TOKEN` and a tier mapping that keeps its internal requests on Model Studio models (`haiku`→`qwen3.6-flash`, `sonnet`→`qwen3.8-flash`, `opus`→`qwen3.8-max`, subagents `auto`, context 983,616; all overridable via `KIMO_DASHSCOPE_CLAUDE_*`). Without `-m`, kimi defaults to `qwen3.8-max` and claude to `auto`. **codex** rides the same compatible-mode origin on the Responses wire (`POST {base}/responses`). kimo passes it as `-c model_providers.dashscope` overlays (`env_key` names `DASHSCOPE_API_KEY` or `MODELSTUDIO_API_KEY`, `requires_openai_auth=false`) and does not modify `config.toml`. **agy** speaks only the Gemini wire and Model Studio exposes no Gemini endpoint, so kimo spawns its loopback Gemini shim in OpenAI-compatible mode (`--upstream-kind openai`): the shim serves `v1beta/models/{model}:generateContent|streamGenerateContent` and posts `{base}/chat/completions` upstream, translating text, images, tool calls, `reasoning_content` and token usage in both directions. The DashScope key is passed to the shim by environment and unset before agy starts, so a Google client is never handed an Alibaba credential; agy authenticates to the shim with its own per-session `GEMINI_API_KEY`. The default model is `qwen3.8-max`.

### Codex Responses providers (`qwencloud`, `xai`, `anthropic`)

`kimo launch codex --provider` can also target three more Responses endpoints. Codex CLI 0.164 accepts only `wire_api = "responses"` (it rejects `chat`). These providers launch **codex** and **claude**; `xai` (`grok`) also launches **kimi**. Codex gets `-c` overlays (`wire_api=responses`). Claude Code speaks `/v1/messages`, so a live `launch claude` starts a localhost proxy that translates to Responses (an `xai-` key, OpenAI, the ChatGPT Codex backend) or Chat Completions (a `grok login` session, QwenCloud, Gemini, vLLM). Kimi Code speaks OpenAI chat completions, so `launch kimi --provider xai` configures `[providers.xai]` and `xai/<model>` aliases in `~/.kimi-code/config.toml` (with `KIMI_MODEL_*` env fallback) using either an API key (`XAI_API_KEY`) or an OAuth session (`XAI_AUTH_TOKEN` from `~/.grok/auth.json`), defaulting to `xai/grok-4.7` with a 500,000 token context window (overridable via `--ctx` or `KIMO_XAI_CTX`). A grok-login token is sent to `cli-chat-proxy.grok.com` with `X-XAI-Token-Auth: xai-grok-cli`; without that header the proxy answers 401 `x_xai_token_auth=none`. The same 401 with `x_xai_token_auth=xai-grok-cli` and `reason=no auth context` is an expired bearer. A stale `eyJ` left in `XAI_API_KEY` or `XAI_AUTH_TOKEN` is replaced by the live session in `~/.grok/auth.json`, and that session is refreshed from its `refresh_token` when it has expired. The upstream key stays in its environment variable; Claude receives only a per-launch token for the proxy. `--provider anthropic` launches Claude Code on `https://api.anthropic.com` directly. `KIMO_ANTHROPIC_BASE_URL` remains the Codex Responses origin and is not applied to Claude Code. `--dry-run` masks the key and does not start the proxy. Nothing is written to `~/.codex/config.toml` or placed in argv. `--oss` is not set, and a ChatGPT login is not required for the Responses providers. Codex's multi-agent tools, and the TUI's `codex_worktrees` MCP server, are sent as `{"type":"namespace"}`. These endpoints reject that variant with HTTP 422. Codex 0.164 also sends `external_web_access` on `web_search`, which xAI rejects with HTTP 400 (`Argument not supported: external_web_access`) before the model runs. The launch disables multi-agent and, through a localhost proxy, flattens remaining namespace tools and drops `external_web_access`, `indexed_web_access`, and `search_context_size`. Cached web search (`external_web_access: false`) is omitted, because these endpoints have no cached-only search. Live and indexed search stay, with `filters`, `user_location`, and `search_content_types` kept. The key still goes only to the upstream.

| Provider | Default endpoint | Credential | Default model | Context |
| --- | --- | --- | --- | --- |
| `qwencloud` | `https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1` | `QWENCLOUD_API_KEY`, else `DASHSCOPE_API_KEY`, else `MODELSTUDIO_API_KEY` | `qwen3.8-max` | 1,000,000 |
| `xai` (`grok`) | `https://api.x.ai/v1` | `XAI_API_KEY`, else `XAI_AUTH_TOKEN` (or `~/.grok/auth.json`) | `grok-4.7` | 500,000 |
| `anthropic` | `https://api.anthropic.com/v1` | `ANTHROPIC_API_KEY`, else `ANTHROPIC_AUTH_TOKEN` | `claude-opus-5-5` | 1,000,000 |

```bash
kimo launch claude --provider xai
kimo launch kimi --provider xai                  # launch kimi with xAI token auth (grok-4.7)
kimo launch kimi --provider grok --model grok-4  # grok alias with explicit model
kimo launch claude --provider openai --model gpt-5.1
kimo launch claude --provider codex
kimo launch claude --provider anthropic          # official Messages API, no proxy
kimo launch claude --provider qwencloud --dry-run
```

`kalidroid` is that dashboard's OpenAI-compatible Chat Completions API (`POST {base}/chat/completions`). `launch claude --provider kalidroid` translates Anthropic Messages onto that wire. Codex only speaks Responses, and this host does not serve `{base}/responses`, so a live `launch codex --provider kalidroid` stops unless `KIMO_KALIDROID_BASE_URL` names a Responses gateway. `--dry-run` still prints the Responses overlays and masks `KALIDROID_API_KEY`. `Kalidroid` is accepted as the same name. A `kalidroid/` prefix on `--model` is stripped. `KIMO_KALIDROID_MODEL` (default `qwen3.8-27b`) and `KIMO_KALIDROID_CTX` (default 131072) override the preset. The catalogue also lists `kimi-k2.6`, `kimi-k2.7-code`, `kimi-k2.7-code-highspeed`, `kimi-k3` and `kimi-k3.1-pro`.

```bash
kimo launch claude --provider kalidroid
kimo launch claude --provider kalidroid --model kimi-k2.7-code --dry-run
```

An `sk-sp-` key selects QwenCloud's token-plan host (`https://token-plan.maas.qwencloudapi.com/compatible-mode/v1`) unless `KIMO_QWENCLOUD_BASE_URL` is set. `KIMO_QWENCLOUD_REGION` changes the pay-as-you-go region (default `ap-southeast-1`). `KIMO_XAI_BASE_URL` and `KIMO_ANTHROPIC_BASE_URL` override those origins. `KIMO_ANTHROPIC_BASE_URL` is the Responses base Codex posts to; it is separate from Claude Code's `ANTHROPIC_BASE_URL`. A `qwencloud/`, `xai/`, `grok/`, or `anthropic/` prefix on `--model` is stripped. `--ctx` overrides the context window Codex is told about (`model_context_window`); for `launch kimi --provider codex|openai` it overrides the window registered as kimi's `max_context_size` instead, clamped to the catalog's `max_context_window`.

With no usable key in the environment at all, `launch kimi --provider dashscope` falls back to the freetier-managed `[providers.alibaba]` block (`kimo freetier`, quota data from `bl usage free`): kimi launches with `-m alibaba/<model>` against its own stored credential, so the free-tier surface works with no secret from kimo. `bl auth login --console --console-site international` refreshes the quota data when it expires. Like every hosted backend it skips host probing, Ollama tag resolution, eviction and tune settings.

`launch kimi --provider alibaba` explicitly targets this `[providers.alibaba]` block even when environment keys (such as `DASHSCOPE_API_KEY`) are present. It defaults the context window to `500,000` tokens (`KIMO_ALIBABA_CTX`, overridable with `--ctx`), syncing `max_context_size` in `~/.kimi-code/config.toml` and exporting `KIMI_MODEL_MAX_CONTEXT_SIZE` so DeepSeek does not hit premature context auto-compaction loops.

### Cloud Provider: abliteration.ai

`--provider abliteration` routes a launch at the hosted [abliteration.ai](https://docs.abliteration.ai) API instead of a self-hosted Ollama daemon. It is currently wired for **`claude`** and **`kimi`**; every other CLI stays on Ollama routing and errors out if you ask it to use the provider.

```bash
export ABLITERATION_API_KEY="ak_..."          # from https://abliteration.ai/console

kimo launch kimi --provider abliteration                          # default: abliterated-model-large-v2
kimo launch claude --provider abliteration --model base           # the image-capable model
kimo launch claude --provider abliteration --dry-run              # inspect routing; the key stays masked

kimo config set cloud_provider abliteration                       # make it the default backend
kimo launch kimi                                                  # ...and launch with no flag at all
kimo launch claude --provider ollama                              # per-launch override back to Ollama
```

| Model | Context | Input | Notes |
|---|---|---|---|
| `abliterated-model-large-v2` | 1,000,000 | text only | default; reasoning up to `max` |
| `abliterated-model-large` | 1,000,000 | text only | previous large; reasoning up to `max` |
| `abliterated-model` | 262,144 | text + images | the only model that accepts images; reasoning up to `xhigh` |

The short aliases `large-v2`, `large` and `base` resolve to those ids, and a Claude-style context suffix (`abliterated-model-large-v2[1m]`) is accepted and stripped. The two large models answer an image request with a `400`, so send screenshots and diagrams to `base`.

What changes versus Ollama routing:

- **No daemon interaction.** There is no host probing, no `/api/tags` resolution, no `/api/show` capability detection, no VRAM eviction and no `tune` registry — the model table above supplies the context window and capabilities instead.
- **The credential rule is inverted, deliberately.** `api.abliteration.ai` is the provider you selected, so the real key is forwarded rather than scrubbed. The scrub still applies to every Ollama host. The key is read from the environment only (`ABLITERATION_API_KEY`, or `ABLIT_KEY` as abliteration.ai's own opencode docs spell it): kimo never writes it to a config file and never passes it in argv, and `--dry-run` masks it.
- **`claude`** gets `ANTHROPIC_BASE_URL` plus bearer auth via `ANTHROPIC_AUTH_TOKEN`, with `ANTHROPIC_API_KEY` left unset so exactly one credential rides the request and Claude Code does not prompt about a "custom API key". The model id carries the `[1m]` suffix where the window is 1M — Claude Code assumes 200K for an unrecognized third-party id otherwise, and strips the suffix before the request. `CLAUDE_CODE_MAX_CONTEXT_TOKENS` and the `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` tiers all point at the same model, so background and summarization calls cannot fall back to real Anthropic ids this key cannot serve.
- **`kimi`** first validates the key against the API's `GET /v1/models`. When validation passes, kimo registers a named `[providers.abliteration]` in `~/.kimi-code/config.toml` — storing only the *name* of the key's env var (`api_key_env = "ABLITERATION_API_KEY"`, never the key itself) — plus one `abliteration/<id>` alias for every model the API serves, and launches on `-m abliteration/<model>`. kimi's provider picker then shows **abliteration** with its live catalogue instead of the synthesized `__kimi_env__`, and the config alias unlocks the graded `/effort` picker. A rejected key (401/403) aborts the launch with an actionable error. If validation cannot complete (offline, upstream error, missing `tomlkit`), kimi falls back to the zero-footprint `KIMI_MODEL_*` env channel — which kimi displays as `__kimi_env__` — and nothing is written to its config. Capabilities come from the model table for known ids (`image_in` only for `base`; remote-only models default to `tool_use,thinking`), the reasoning key is `reasoning_content` (the field abliteration.ai returns on `/v1/chat/completions`), and a thinking effort above the model's ceiling is capped with a warning.

`--ctx` still works and is capped at the selected model's window. `--dry-run` reports the provider, the resolved window and capabilities alongside the usual argv and masked env.

### Environment Overrides

- `ABLITERATION_API_KEY` (or `ABLIT_KEY`): abliteration.ai `ak_...` API key. Environment only — never persisted by kimo.
- `KIMO_CLOUD_PROVIDER`: Default `launch` backend (`ollama` or `abliteration`); overrides the `cloud_provider` config key. `--provider` beats both.
- `KIMO_ABLITERATION_BASE_URL`: Override the API origin (default `https://api.abliteration.ai`).
- `KIMO_VLLM_BASE_URL`: Override the vLLM `/v1` base (default `http://127.0.0.1:8000/v1`). `VLLM_BASE_URL` is accepted too; an explicit value disables endpoint discovery.
- `VLLM_API_KEY`: Bearer token when vLLM was started with `--api-key`. Never written to config. When unset, `$HOME/vllm/api.key` is read for a loopback server.
- `KIMO_VLLM_API_KEY_FILE`: Key file used when `VLLM_API_KEY` is unset. Applies to any base, not only loopback.
- `KIMO_VLLM_BASE_URLS`: Comma- or space-separated fallback `/v1` bases probed when no base is configured and the default does not answer (default: `http://127.0.0.1:8000/v1`, then `http://127.0.0.1:18000/v1`).
- `KIMO_VLLM_CTX`: Context window used when the server does not report `max_model_len` (default 32768).
- `OLLAMA_REMOTE_URL`: Override default remote URL (defaults to `http://127.0.0.1:11438`).
- `OLLAMA_LOCAL_URL`: Override default local URL (defaults to `http://127.0.0.1:11434`).
- `KIMO_KIMI_EFFORT` (or `OM_KIMI_EFFORT`): Default thinking effort level for Kimi Code CLI (`low`, `medium`, `high`, `xhigh`, `max`).
- `KIMO_KIMI_CAPABILITIES` (or `OM_KIMI_CAPABILITIES`): Override detected capabilities (`tool_use`, `thinking`, `image_in`).
- `KIMO_KIMI_REGISTER_ALL`: Register every model the host serves into the kimi config (default `1`). Set `0` to only register the launched model.
- `QWEN_CODE_API_TIMEOUT_MS`: Per-request timeout for `launch qwen`. Defaults to `600000` when unset; set your own value to override.
- `KIMO_RUNTIME_DIR`: Private per-user directory for session claims and config locks. Defaults to `$XDG_RUNTIME_DIR/kimo`, else `${TMPDIR:-/tmp}/kimo-<uid>`; kimo refuses a directory that is a symlink or owned by another user.
- `KIMO_AGY_CLAIM_DIR`: Session claim directory for concurrent Antigravity sessions (default `$KIMO_RUNTIME_DIR/agy-claims`).
- `KIMO_GROK_CLAIM_DIR`: Session claim directory for concurrent Grok sessions (default `$KIMO_RUNTIME_DIR/grok-claims`).
- `KIMO_KIMI_CONFIG_LOCK`: File lock path for concurrent Kimi config updates (default `$KIMO_RUNTIME_DIR/kimi-config.lock`).

---

## License

GNU General Public License v3.0 (GPL-3.0). See [LICENSE](LICENSE) for details.
