#!/usr/bin/env bash
# Independent package evidence. Never adds cases to the App Simulator selection.
set -euo pipefail
if [[ ${LEGADO_RUNTIME_SOURCE_ONLY:-} != 1 || -z ${DEVELOPER_DIR:-} ]]; then
  echo 'Use LEGADO_RUNTIME_SOURCE_ONLY=1 and the already selected DEVELOPER_DIR.' >&2
  exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
python3 "$SCRIPT_DIR/original-api-package-tools.py" run \
  --work "$REPO_DIR/.build/reader-renewal-original-api"
