#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------- backup_prune_test.sh ----------
# `kimo gemini` and `kimo freetier` back up the Kimi config they rewrite
# (<config>.before-gemini-* / <config>.before-freetier-*) and keep only the 5
# newest. Each test seeds 7 old backups next to a throwaway Kimi config, runs
# a real (offline, --from-json) write, and checks what is left; --dry-run must
# neither back up nor prune.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
WORK="$(mktemp -d)"

seed() { # <config> <kind> : a config plus 7 backups dated 2020-01-01..07
    printf 'default_model = "existing/model"\n\n[providers.existing]\ntype = "openai"\nbase_url = "http://127.0.0.1:1/v1"\napi_key = "x"\n' > "$1"
    local day
    for day in 1 2 3 4 5 6 7; do
        : > "$1.before-$2-2020010${day}T000000+0000"
        touch -d "2020-01-0${day} 00:00:00" "$1.before-$2-2020010${day}T000000+0000"
    done
}
count() { find "$(dirname "$1")" -maxdepth 1 -name "$(basename "$1").before-$2-*" | wc -l; }
newest_kept() { [[ -n "$(find "$(dirname "$1")" -maxdepth 1 -name "$(basename "$1").before-$2-*" -newer "$1.before-$2-20200107T000000+0000")" ]] && echo yes || echo no; }

GEMINI_FIXTURE="${WORK}/models.json"
cat > "${GEMINI_FIXTURE}" <<'EOF'
{"models": [{"name": "models/gemini-2.5-flash", "displayName": "Gemini 2.5 Flash", "inputTokenLimit": 1048576,
             "outputTokenLimit": 65536, "supportedGenerationMethods": ["generateContent"], "thinking": true}]}
EOF
FREETIER_FIXTURE="${WORK}/rows.json"
echo '[{"model": "qwen-plus", "remaining": 1000000, "expires": "", "type": ""}]' > "${FREETIER_FIXTURE}"

for kind in gemini freetier; do
    echo "[*] ${kind}"
    cfg="${WORK}/${kind}-kimi.toml"
    seed "${cfg}" "${kind}"
    if [[ "${kind}" == gemini ]]; then
        args=(gemini --config "${cfg}" --from-json "${GEMINI_FIXTURE}" --api-key "AIzaSyTestMockKey123")
    else
        args=(freetier --config "${cfg}" --from-json "${FREETIER_FIXTURE}" --api-key "sk-test-key")
    fi

    "${KIMO}" "${args[@]}" --dry-run >/dev/null 2>&1 || true
    check "${kind} --dry-run neither backs up nor prunes" "7" "$(count "${cfg}" "${kind}")"

    rc=0
    out=$("${KIMO}" "${args[@]}" 2>&1) || rc=$?
    check "${kind} write succeeds" "0" "${rc}"
    [[ "${rc}" -eq 0 ]] || echo "    ${out//$'\n'/$'\n'    }"
    check "${kind} keeps exactly 5 backups" "5" "$(count "${cfg}" "${kind}")"
    check "${kind} keeps the new backup" "yes" "$(newest_kept "${cfg}" "${kind}")"
    check "${kind} prunes the oldest backups first" "no" \
        "$([[ -e "${cfg}.before-${kind}-20200101T000000+0000" || -e "${cfg}.before-${kind}-20200103T000000+0000" ]] && echo yes || echo no)"
    check "${kind} keeps the most recent old backup" "yes" \
        "$([[ -e "${cfg}.before-${kind}-20200107T000000+0000" ]] && echo yes || echo no)"
done

harness_summary "backup_prune_test.sh"
