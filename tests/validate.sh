#!/bin/bash
# foamy-kit 0.9.0 600483edb58f93da9e745500dac4efa7c5ef9fd23151a67fc2106ee1e07fbca9 — do not edit; change foamy-kit and run sync
# The one validation command: kit checks, linters, formatters, native helper
# tests and the repository's own tests (tests/suite.sh). Nonzero on failure.
#   tests/validate.sh [--ci] [--fast] [--only|--skip CHECKS] [--update-baseline [CHECKS]] [--list]
# Run `mise install` first (mise.toml pins the tools). kit/tooling/validate.py
# does the work; see foamy-kit's README, "Tooling".
set -euo pipefail
exec python3 -I "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../kit/tooling/validate.py" "$@"
