#!/usr/bin/env bash
# Run one command inside the hermetic test environment (see harness.sh), e.g.
#     tests/lib/run-hermetic.sh python3 tests/quota_adapters_test.py
set -euo pipefail
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
"$@"
