#!/bin/bash
# foamy-kit 0.7.0 31cd6228f43b6b189e993ba517cbf8f18c4ba2681a4e71be49b853a39d6114ba — do not edit; change foamy-kit and run sync
# Build, verify or test this plugin's native helper; see kit/native/native.py.
#   kit/native/build-native.sh . [--verify [--out DIR] | --test] [--crate DIR] [--bin NAME]
# Needs rustup (the toolchain in rust-toolchain.toml, with its musl targets),
# Python 3.11 or newer and file(1). Nothing outside this plugin is used.
set -euo pipefail
exec python3 -I "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/native.py" "$@"
