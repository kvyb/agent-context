#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_BRANCH="main"
MODE="status"
REPO_ROOT="${AGENT_CONTEXT_REPO_ROOT:-}"
APP_BUNDLE_PATH="${AGENT_CONTEXT_APP_BUNDLE_PATH:-${HOME}/Applications/Agent Context.app}"
RESTART_AFTER_UPDATE=1

usage() {
  cat <<'USAGE'
Usage: scripts/update.sh [options]

Options:
  --status             Check update status only (default)
  --apply              Pull latest main, rebuild, and optionally restart
  --repo <path>        Repository root path
  --bundle <path>      App bundle output path for rebuild
  --branch <name>      Target branch (default: main)
  --no-restart         Do not relaunch app after successful update
  -h, --help           Show this help
USAGE
}

is_repo_root() {
  local path="$1"
  [[ -d "${path}/.git" && -f "${path}/Package.swift" ]]
}

canonical_path() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    (cd "${path}" && pwd)
  else
    local parent
    parent="$(dirname "${path}")"
    local base
    base="$(basename "${path}")"
    (cd "${parent}" && printf "%s/%s\n" "$(pwd)" "${base}")
  fi
}

find_repo_root() {
  local start="$1"
  local candidate
  candidate="$(canonical_path "${start}")"

  while true; do
    if is_repo_root "${candidate}"; then
      echo "${candidate}"
      return 0
    fi

    local parent
    parent="$(dirname "${candidate}")"
    if [[ "${parent}" == "${candidate}" ]]; then
      return 1
    fi
    candidate="${parent}"
  done
}

emit_status() {
  local action="$1"
  local message="$2"

  echo "repo=${REPO_ROOT}"
  echo "branch=${CURRENT_BRANCH}"
  echo "target_branch=${TARGET_BRANCH}"
  echo "local_commit=${LOCAL_COMMIT}"
  echo "remote_commit=${REMOTE_COMMIT}"
  echo "merge_base=${MERGE_BASE}"
  echo "relationship=${RELATIONSHIP}"
  echo "dirty=${DIRTY}"
  echo "action=${action}"
  echo "message=${message}"
}

determine_status() {
  git -C "${REPO_ROOT}" fetch --quiet origin "${TARGET_BRANCH}"

  CURRENT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)"
  LOCAL_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  REMOTE_COMMIT="$(git -C "${REPO_ROOT}" rev-parse "origin/${TARGET_BRANCH}")"
  MERGE_BASE="$(git -C "${REPO_ROOT}" merge-base HEAD "origin/${TARGET_BRANCH}")"

  if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain)" ]]; then
    DIRTY=1
  else
    DIRTY=0
  fi

  if [[ "${LOCAL_COMMIT}" == "${REMOTE_COMMIT}" ]]; then
    RELATIONSHIP="upToDate"
  elif [[ "${LOCAL_COMMIT}" == "${MERGE_BASE}" ]]; then
    RELATIONSHIP="behind"
  elif [[ "${REMOTE_COMMIT}" == "${MERGE_BASE}" ]]; then
    RELATIONSHIP="ahead"
  else
    RELATIONSHIP="diverged"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)
      MODE="status"
      shift
      ;;
    --apply)
      MODE="apply"
      shift
      ;;
    --repo)
      REPO_ROOT="${2:-}"
      shift 2
      ;;
    --bundle)
      APP_BUNDLE_PATH="${2:-}"
      shift 2
      ;;
    --branch)
      TARGET_BRANCH="${2:-}"
      shift 2
      ;;
    --no-restart)
      RESTART_AFTER_UPDATE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${REPO_ROOT}" ]]; then
  if is_repo_root "${SCRIPT_DIR}/.."; then
    REPO_ROOT="$(canonical_path "${SCRIPT_DIR}/..")"
  elif find_repo_root "$(pwd)" >/dev/null 2>&1; then
    REPO_ROOT="$(find_repo_root "$(pwd)")"
  elif is_repo_root "${HOME}/agent-context"; then
    REPO_ROOT="$(canonical_path "${HOME}/agent-context")"
  else
    echo "error: repository root not found. Set AGENT_CONTEXT_REPO_ROOT or pass --repo." >&2
    exit 2
  fi
else
  REPO_ROOT="$(canonical_path "${REPO_ROOT}")"
fi

if ! is_repo_root "${REPO_ROOT}"; then
  echo "error: invalid repository root: ${REPO_ROOT}" >&2
  exit 3
fi

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is required." >&2
  exit 4
fi

determine_status

if [[ "${MODE}" == "status" ]]; then
  case "${RELATIONSHIP}" in
    upToDate)
      emit_status "none" "Already up to date."
      ;;
    behind)
      emit_status "none" "Update available."
      ;;
    ahead)
      emit_status "none" "Local branch is ahead of origin/${TARGET_BRANCH}."
      ;;
    diverged)
      emit_status "none" "Local branch has diverged from origin/${TARGET_BRANCH}."
      ;;
  esac
  exit 0
fi

if [[ "${CURRENT_BRANCH}" != "${TARGET_BRANCH}" ]]; then
  emit_status "none" "Update requires local branch ${TARGET_BRANCH}."
  exit 10
fi

if [[ "${DIRTY}" == "1" ]]; then
  emit_status "none" "Update cancelled because repository has uncommitted changes."
  exit 11
fi

case "${RELATIONSHIP}" in
  upToDate)
    emit_status "none" "Already up to date."
    exit 0
    ;;
  ahead)
    emit_status "none" "Local branch is already ahead of origin/${TARGET_BRANCH}."
    exit 0
    ;;
  diverged)
    emit_status "none" "Local branch has diverged from origin/${TARGET_BRANCH}."
    exit 12
    ;;
  behind)
    ;;
esac

git -C "${REPO_ROOT}" pull --ff-only origin "${TARGET_BRANCH}"

if [[ -x "${REPO_ROOT}/scripts/build_macos_app.sh" ]]; then
  "${REPO_ROOT}/scripts/build_macos_app.sh" "${APP_BUNDLE_PATH}"
else
  (
    cd "${REPO_ROOT}"
    swift build -c release --product agent-context
  )
fi

determine_status
emit_status "updated" "Updated to $(echo "${LOCAL_COMMIT}" | cut -c1-8)."

if [[ "${RESTART_AFTER_UPDATE}" == "1" ]]; then
  if [[ -d "${APP_BUNDLE_PATH}" ]]; then
    open -n "${APP_BUNDLE_PATH}"
  elif [[ -x "${REPO_ROOT}/.build/release/agent-context" ]]; then
    "${REPO_ROOT}/.build/release/agent-context" >/dev/null 2>&1 &
  fi
fi
