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
| `make test-qwen` | Headless smoke test of the `qwen` launch branch: asserts the argv/env kimo passes (api-key scrubbing, `QWEN_CODE_API_TIMEOUT_MS`). Add `LIVE=1` for an opt-in live `-p` turn against a reachable Ollama host (`KIMO_SMOKE_HOST`/`KIMO_SMOKE_MODEL` override) |
| `make test-claude` | Headless smoke test of the `claude` launch branch: asserts the env kimo passes (api-key scrubbing, `CLAUDE_CODE_*` defaults incl. unknown-model window enforcement and telemetry/MCP flags with user overrides honoured, `--ctx` → `OLLAMA_CONTEXT_LENGTH`, `API_TIMEOUT_MS` passthrough). Add `LIVE=1` for an opt-in live `-p` turn |
| `make test-agy` | Headless smoke test of the `agy` launch branch: asserts shim liveness/reaping, settings patch + restore, and that `GEMINI_API_KEY` is never scrubbed (it only reaches the loopback shim, whose upstream requests carry no auth). Add `LIVE=1` for an opt-in live `-p` turn |
| `make test-opencode` | Headless smoke test of the `opencode` launch branch: asserts the argv/env kimo passes (host env, `OPENAI_API_KEY`/`ANTHROPIC_API_KEY` scrub for non-local hosts). opencode routes via its own provider config and reads no base-url env, so the scrub is defence-in-depth. Add `LIVE=1` for an opt-in live `run` turn against an isolated `HOME` with a throwaway provider (`KIMO_SMOKE_HOST`/`KIMO_SMOKE_MODEL` override) |
| `make test-codex` | Headless smoke test of the `codex` launch branch: asserts the argv/env kimo passes (`--oss`, `--local-provider ollama`, `CODEX_OSS_BASE_URL` host routing, `OPENAI_API_KEY` default). Add `LIVE=1` for an opt-in live `exec` turn against a reachable Ollama host (`KIMO_SMOKE_HOST`/`KIMO_SMOKE_MODEL` override) |
| `make test-cursor` | Headless smoke test of the `cursor` launch branch: asserts the argv/env kimo passes (`--model`, `CURSOR_MODEL`, `CURSOR_API_ENDPOINT`/`CURSOR_API_BASE_URL`/`CURSOR_LOCAL_AGENT_BASE_URL` host routing, override handling) and the `cursor` → `cursor-agent` binary fallback. Add `LIVE=1` for an opt-in live `-p` turn against a reachable Ollama host (`KIMO_SMOKE_HOST`/`KIMO_SMOKE_MODEL` override) |
| `make test-grok` | Headless smoke test of the `grok` launch branch: asserts the argv/env kimo passes (`--model`, `GROK_MODELS_BASE_URL` host routing, forced `XAI_API_KEY` scrub for all hosts, exit-code propagation) and the `--ctx` config.toml `context_window` patch/revert lifecycle. Add `LIVE=1` for an opt-in live `-p` turn against a reachable Ollama host (`KIMO_SMOKE_HOST`/`KIMO_SMOKE_MODEL` override) |
| `make test-thinking-tools` | Checks the thinking/tools capability handling: `_kimi_model_spec` unit checks (capability mapping `thinking`/`tools`/`vision` → `thinking`/`tool_use`/`image_in`, probe-failure fallback to `tool_use`, override precedence, ctx precedence flag > runtime > architecture) plus launch-branch integration (kimi env channel exports thinking vars only for thinking models, scrubs stale inherited effort on non-thinking models, honours `KIMO_KIMI_EFFORT`/`KIMO_KIMI_REASONING_KEY`/`KIMO_KIMI_CAPABILITIES`) |
| `make test-gemini` | Headless smoke test of `kimo gemini` model sync into Kimi Code: asserts `/v1beta/models` parsing, non-chat filtering, `--stable-only`/`--all` flags, token limits mapping, thinking capability, valid TOML generation, idempotency, and backup creation |
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
| `scan`, `discover [target]` | Discover active Ollama instances on LAN/subnets (`-m`, `--save`) | `kimo scan -m` |
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
| `rm <model>` | Delete a model from target Ollama server | `kimo rm old-model` |
| `stream <model>` | Pin model for durable availability via keepalive daemon | `kimo stream model --status` |
| `run <model> [args]`| Run model directly with auto-routing to remote GPU | `kimo run kalidroid-27b` |
| `launch <cli> [opts]`| Launch external CLI with automatic Ollama routing | `kimo launch grok --model 27b` |
| `install [cli\|all]` | Install/update external CLIs (`kimi`, `claude`, `grok`, `codex`, `qwen`, etc.) | `kimo install kimi` |
| `update [cli\|all]`  | Check for updates for all installed CLIs, or apply updates | `kimo update` |
| `completion [sh]`    | Generate shell tab-completion script for Bash or Zsh | `kimo completion bash` |
| `freetier [opts]`    | Sync Kimi config with Model Studio free-tier quotas (`bl usage free`) | `kimo freetier --verify-prune` |
| `gemini [opts]`      | Register Gemini API models (with exact token limits) into Kimi Code | `kimo gemini --verify-prune` |

---

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
5. **CLI Ecosystem**: Installation status, versions, and paths for all supported CLIs (claude, codex, qwen, grok, kimi, cursor, opencode, cyberstrike, agy, openclaw, hermes).

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
| `kimi_effort` | Default thinking effort for Kimi (`low`, `medium`, `high`, `xhigh`, `max`) | `default` |
| `kimi_context` | Default context window length in tokens for Kimi Code CLI | `auto` (model architecture/runtime) |
| `no_color` | Disable ANSI terminal color codes (`true`/`false`) | `false` |

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
- Integrated streaming pull progress on the destination host.
- Conflict detection with actionable `--force` guidance when digests differ.

---

## Network Discovery & Instance Scanning (`scan` / `discover`)

`kimo scan` is a high-performance multithreaded network discovery tool designed to probe local physical interfaces, CIDR subnets, IP ranges, or specific endpoints to identify reachable Ollama instances, measure round-trip latency, inspect model catalogs, and report GPU VRAM residency:

```bash
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

# Automatically discover and save remote node to persistent ~/.config/kimo/config
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
```

Metrics reported:
- **Time to First Token (TTFT)**: Accurate prompt processing and cold/warm start latency.
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
```

### Environment Overrides

- `OLLAMA_REMOTE_URL`: Override default remote URL (defaults to `http://127.0.0.1:11438`).
- `OLLAMA_LOCAL_URL`: Override default local URL (defaults to `http://127.0.0.1:11434`).
- `KIMO_KIMI_EFFORT` (or `OM_KIMI_EFFORT`): Default thinking effort level for Kimi Code CLI (`low`, `medium`, `high`, `xhigh`, `max`).
- `KIMO_KIMI_CAPABILITIES` (or `OM_KIMI_CAPABILITIES`): Override detected capabilities (`tool_use`, `thinking`, `image_in`).
- `KIMO_KIMI_REGISTER_ALL`: Register every model the host serves into the kimi config (default `1`). Set `0` to only register the launched model.
- `QWEN_CODE_API_TIMEOUT_MS`: Per-request timeout for `launch qwen`. Defaults to `600000` when unset; set your own value to override.
- `KIMO_AGY_CLAIM_DIR`: Session claim directory for concurrent Antigravity sessions.
- `KIMO_GROK_CLAIM_DIR`: Session claim directory for concurrent Grok sessions.
- `KIMO_KIMI_CONFIG_LOCK`: File lock path for concurrent Kimi config updates.

---

## License

GNU General Public License v3.0 (GPL-3.0). See [LICENSE](LICENSE) for details.
