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
- **Hosted Cloud Provider**: `launch --provider abliteration` routes `claude` and `kimi` at the [abliteration.ai](https://docs.abliteration.ai) Anthropic-/OpenAI-compatible API instead of a self-hosted Ollama daemon — no host probing, no model eviction, and the API key stays in the environment only.
- **DashScope (Alibaba Model Studio)**: `launch --provider dashscope` routes `kimi` and `claude` at Model Studio — the key's class picks the surface (`sk-ws-`/`sk-` → pay-as-you-go intl, `sk-sp-` → token-plan); kimi rides a zero-footprint env channel, claude the Anthropic-compatible `/apps/anthropic` endpoint, and with no env key kimi falls back to the freetier-managed `alibaba/` aliases.

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
| `make test-agy` | Headless smoke test of the `agy` launch branch: asserts shim liveness/reaping, settings patch + restore, and that `GEMINI_API_KEY` is never scrubbed (it only reaches the loopback shim, whose upstream requests carry no auth). Add `LIVE=1` for an opt-in live `-p` turn |
| `make test-opencode` | Headless smoke test of the `opencode` launch branch: asserts the argv/env kimo passes (host env, `OPENAI_API_KEY`/`ANTHROPIC_API_KEY` scrub for non-local hosts). opencode routes via its own provider config and reads no base-url env, so the scrub is defence-in-depth. Add `LIVE=1` for an opt-in live `run` turn against an isolated `HOME` with a throwaway provider (`KIMO_SMOKE_HOST`/`KIMO_SMOKE_MODEL` override) |
| `make test-codex` | Headless smoke test of the `codex` launch branch: asserts the argv/env kimo passes (`--oss`, `--local-provider ollama`, `CODEX_OSS_BASE_URL` host routing, `OPENAI_API_KEY` default). Add `LIVE=1` for an opt-in live `exec` turn against a reachable Ollama host (`KIMO_SMOKE_HOST`/`KIMO_SMOKE_MODEL` override) |
| `make test-codex-auth` | Isolated Codex native command forwarding, cloud/Ollama precedence, credentials, and Kimi model sync with backups |
| `make test-cursor` | Headless smoke test of the `cursor` launch branch: asserts the argv/env kimo passes (`--model`, `CURSOR_MODEL`, `CURSOR_API_ENDPOINT`/`CURSOR_API_BASE_URL`/`CURSOR_LOCAL_AGENT_BASE_URL` host routing, override handling) and the `cursor` → `cursor-agent` binary fallback. Add `LIVE=1` for an opt-in live `-p` turn against a reachable Ollama host (`KIMO_SMOKE_HOST`/`KIMO_SMOKE_MODEL` override) |
| `make test-grok` | Headless smoke test of the `grok` launch branch: asserts the argv/env kimo passes (`--model`, `GROK_MODELS_BASE_URL` host routing, forced `XAI_API_KEY` scrub for all hosts, exit-code propagation) and the `--ctx` config.toml `context_window` patch/revert lifecycle. Add `LIVE=1` for an opt-in live `-p` turn against a reachable Ollama host (`KIMO_SMOKE_HOST`/`KIMO_SMOKE_MODEL` override) |
| `make test-thinking-tools` | Checks the thinking/tools capability handling: `_kimi_model_spec` unit checks (capability mapping `thinking`/`tools`/`vision` → `thinking`/`tool_use`/`image_in`, probe-failure fallback to `tool_use`, override precedence, ctx precedence flag > runtime > architecture) plus launch-branch integration (kimi env channel exports thinking vars only for thinking models, scrubs stale inherited effort on non-thinking models, honours `KIMO_KIMI_EFFORT`/`KIMO_KIMI_REASONING_KEY`/`KIMO_KIMI_CAPABILITIES`) |
| `make test-gemini` | Headless smoke test of `kimo gemini` model sync into Kimi Code: asserts `/v1beta/models` parsing, non-chat filtering, `--stable-only`/`--all` flags, token limits mapping, thinking capability, valid TOML generation, idempotency, and backup creation |
| `make test-abliteration` | Headless smoke test of the abliteration.ai cloud provider (`launch --provider abliteration`): base-URL routing for both API surfaces, the forwarded key never reaching argv or console, Claude's `[1m]` context suffix and tier overrides, kimi's zero-footprint env channel, per-model capabilities/effort ceilings, provider precedence (flag > env > config), and the absence of any Ollama probing |
| `make test-dashscope` | Headless smoke test of the DashScope cloud provider (`launch --provider dashscope`): intl compatible-mode routing, default/explicit/`--ctx` model selection, `DASHSCOPE_API_KEY` with `MODELSTUDIO_API_KEY` fallback, placeholder and missing-key rejection, kimi's zero-footprint `KIMI_MODEL_*` env channel (wire type, base URL, context, reasoning key), provider precedence, remote-host key scrubbing, and the absence of any Ollama probing |
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
| `make test-shim` | Gemini shim contract: `model:tag` paths, JSON-array/SSE streaming, mid-stream errors, tools, images, `countTokens`, request validation |
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
| `gemini [opts]`      | Register Gemini API models (with exact token limits) into Kimi Code | `kimo gemini --verify-prune` |
| `codex [opts\|command]` | Inspect Codex authentication, sync models into Kimi, or forward native Codex commands | `kimo codex login --device-auth` |
| `quota [cli] [opts]` | Check provider usage and every supported CLI account | `kimo quota codex --json` |

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
| `opencode` | Selected provider's OpenRouter budget or configured Ollama status | Reads local JSON/JSONC config and environment references; remote organization and managed overrides are not evaluated. |
| `hermes` | Configured OpenRouter budget, Ollama status, or local session usage | Provider environment / `.hermes/.env`; optionally set `HERMES_USAGE_FILE` to an existing `--usage-file` report. Local estimates are labelled separately. |
| `grok` | Native subscription credits, billing period, on-demand cap/spend, prepaid balance, plan, and billing history | Existing `grok login`; probes `_x.ai/billing` via `grok agent stdio`. Uses the native client's authentication/refresh. Older clients without billing support can fall back to a configured OpenRouter/Ollama backend. [Official billing protocol](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/extensions/billing.rs) |
| `cyberstrike` | Configured OpenRouter budget or Ollama status | Provider environment; otherwise guidance for checking the configured provider. |
| `gh` | Native GitHub API rate-limit resources | Existing `gh` authentication; these limits do not represent Copilot premium requests. |

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

Sync reads the visible models, context sizes, input capabilities, and reasoning levels from `$CODEX_HOME/models_cache.json`; start Codex once to populate that catalog. Thinking models also get an `off_effort`, which kimi 2.x requires before it runs them with thinking switched off (prompt mode). It writes `[providers.codex]` (environment reference to `CODEX_AUTH_TOKEN`) or `[providers.openai]` (reference to `OPENAI_API_KEY`), plus `<backend>/<slug>` model aliases. An explicit `--model` is registered on its own, so the platform backend works on a box that never ran the Codex CLI. Launching Kimi syncs the selected model automatically. Existing comments and unrelated settings survive, changed files receive a backup, and concurrent writes use the Kimi config lock. `CODEX_HOME`, `KIMI_CODE_HOME`, and `KIMI_CONFIG` overrides are supported.

A ChatGPT access token expires after a few hours, so kimo renews it from `auth.json`'s `refresh_token` (the same call the Codex CLI makes) whenever `launch --provider codex`, `kimo codex --token` or `--export` needs a working credential. The renewed token is written back atomically at mode `0600` and is never printed or passed in argv; no plaintext backup of a credential file is left behind. Set `KIMO_CODEX_NO_REFRESH=1` to stay offline (`KIMO_CODEX_TOKEN_URL` / `KIMO_CODEX_REFRESH_TIMEOUT` override the endpoint and its timeout). `kimo codex` reports the refresh token and last renewal; `kimo codex --json` exposes `refreshable` and `last_refresh`. OpenAI Platform API keys cannot authenticate the ChatGPT endpoint — use `--provider openai` for those.

## Google Gemini API Model Sync (`gemini`)

`kimo gemini` registers Google Gemini API models directly into Kimi Code (`~/.kimi-code/config.toml`). It queries the `/v1beta/models` endpoint (paginated) for every model visible to your API key, maps each model's genuine architectural token limits (`inputTokenLimit` &rarr; `max_context_size`, `outputTokenLimit` &rarr; `max_output_size`), detects thinking capability, and populates a managed `[providers.gemini]` block with native `google-genai` provider protocol and `[models."gemini/<id>"]` aliases.

Non-chat models (media generation, TTS, live audio streams, embeddings, and autonomous agents) are automatically filtered out unless `--all` is passed. Like other `kimo` config mutations, edits are surgical, validated against `kimi doctor`, and preceded by timestamped backups (`config.toml.before-gemini-*`).

```bash
# Preview models that would be added (writes nothing)
kimo gemini --dry-run

# Probe candidate models with a 1-token prompt, prune any failing models, and write config
kimo gemini --verify --verify-prune

# Register only stable release models (drop preview / experimental tags)
kimo gemini --stable-only

# Reference GEMINI_API_KEY environment variable instead of hardcoding key into config.toml
kimo gemini --api-key-env GEMINI_API_KEY

# Set Gemini 2.5 Flash as the default model in Kimi Code
kimo gemini --set-default gemini/gemini-2.5-flash

# Launch Kimi Code CLI directly with a registered Gemini model
kimi -m gemini/gemini-2.5-flash
kimi -m gemini/gemini-2.5-pro
```

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

`--provider dashscope` routes a launch at Alibaba Model Studio. The credential's class picks the surface: `sk-ws-`/`sk-` keys go to the pay-as-you-go international endpoint (`https://dashscope-intl.aliyuncs.com/compatible-mode/v1`), `sk-sp-` token-plan keys to the subscription endpoint (`https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`) — each class 401s on the other's surface. It is wired for **`kimi`** and **`claude`**; every other CLI stays on Ollama routing and errors out if you ask it to use the provider.

```bash
export DASHSCOPE_API_KEY="sk-..."        # MODELSTUDIO_API_KEY is accepted too

kimo launch kimi --provider dashscope                       # default: qwen3.8-max
kimo launch kimi --provider dashscope --model qwen3-coder-plus
kimo launch claude --provider dashscope                     # Anthropic wire, tier-mapped
kimo launch kimi --provider dashscope --ctx 131072 --dry-run

kimo config set cloud_provider dashscope                    # make it the default backend
```

kimi rides its zero-footprint `KIMI_MODEL_*` env channel (wire type `openai`, reasoning key `reasoning_content`, context 1,000,000 unless `--ctx` or `KIMO_DASHSCOPE_CTX` says otherwise), so nothing is written to kimi's config and the key never reaches argv or disk. claude rides each surface's Anthropic-compatible `/apps/anthropic` endpoint with the bearer in `ANTHROPIC_AUTH_TOKEN` and a tier mapping that keeps its internal requests on Model Studio models (`haiku`→`qwen3.6-flash`, `sonnet`→`qwen3.8-flash`, `opus`→`qwen3.8-max`, subagents `auto`, context 983,616; all overridable via `KIMO_DASHSCOPE_CLAUDE_*`). Without `-m`, kimi defaults to `qwen3.8-max` and claude to `auto`.

With no usable key in the environment at all, `launch kimi --provider dashscope` falls back to the freetier-managed `[providers.alibaba]` block (`kimo freetier`, quota data from `bl usage free`): kimi launches with `-m alibaba/<model>` against its own stored credential, so the free-tier surface works with no secret from kimo. `bl auth login --console --console-site international` refreshes the quota data when it expires. Like every hosted backend it skips host probing, Ollama tag resolution, eviction and tune settings.

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
- **`kimi`** uses the zero-footprint `KIMI_MODEL_*` env channel rather than the config-alias path used for Ollama, because an alias would have to store a third-party API key in plaintext in `~/.kimi-code/config.toml`. Nothing is written to kimi's config. Capabilities come from the model table (`image_in` only for `base`), the reasoning key is `reasoning_content` (the field abliteration.ai returns on `/v1/chat/completions`), and a thinking effort above the model's ceiling is capped with a warning.

`--ctx` still works and is capped at the selected model's window. `--dry-run` reports the provider, the resolved window and capabilities alongside the usual argv and masked env.

### Environment Overrides

- `ABLITERATION_API_KEY` (or `ABLIT_KEY`): abliteration.ai `ak_...` API key. Environment only — never persisted by kimo.
- `KIMO_CLOUD_PROVIDER`: Default `launch` backend (`ollama` or `abliteration`); overrides the `cloud_provider` config key. `--provider` beats both.
- `KIMO_ABLITERATION_BASE_URL`: Override the API origin (default `https://api.abliteration.ai`).
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
