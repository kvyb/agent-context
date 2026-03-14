#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: ./scripts/agent_context_query.sh \"<question>\"" >&2
  exit 2
fi

QUERY="$*"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_query() {
  if command -v agent-context >/dev/null 2>&1; then
    agent-context query "$QUERY" --json
    return
  fi

  cd "$ROOT_DIR"
  swift run agent-context query "$QUERY" --json
}

RAW_OUTPUT="$(run_query 2>&1)" || {
  printf '%s\n' "$RAW_OUTPUT" >&2
  exit 1
}

JSON_PAYLOAD="$(printf '%s\n' "$RAW_OUTPUT" | sed -n '/^{/,$p')"
if [ -n "$JSON_PAYLOAD" ]; then
  printf '%s\n' "$JSON_PAYLOAD"
else
  printf '%s\n' "$RAW_OUTPUT"
fi
