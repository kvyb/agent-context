#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_REPO_URL="$(git -C "${SCRIPT_DIR}/.." remote get-url origin 2>/dev/null || true)"
if [[ -z "${DEFAULT_REPO_URL}" ]]; then
  DEFAULT_REPO_URL="https://github.com/kvyb/agent-context.git"
fi

REPO_URL="${AGENT_CONTEXT_REPO_URL:-${DEFAULT_REPO_URL}}"
INSTALL_DIR="${AGENT_CONTEXT_INSTALL_DIR:-${HOME}/agent-context}"
APP_BUNDLE_PATH="${AGENT_CONTEXT_APP_BUNDLE_PATH:-${HOME}/Applications/Agent Context.app}"
BRANCH="${AGENT_CONTEXT_INSTALL_BRANCH:-main}"
LAUNCH_AFTER_INSTALL=1
CLI_BIN_DIR="${AGENT_CONTEXT_CLI_BIN_DIR:-${HOME}/.local/bin}"

usage() {
  cat <<'USAGE'
Usage: scripts/install.sh [options]

Options:
  --repo-url <url>     Git repository URL (default: current origin or official public repo)
  --install-dir <path> Install/update checkout path (default: ~/agent-context)
  --app-path <path>    App bundle destination path (default: ~/Applications/Agent Context.app)
  --branch <name>      Branch to install (default: main)
  --cli-bin-dir <path> Directory where agent-context CLI symlink is installed (default: ~/.local/bin)
  --no-launch          Do not launch app after installation
  -h, --help           Show this help
USAGE
}

is_repo_root() {
  local path="$1"
  [[ -d "${path}/.git" && -f "${path}/Package.swift" ]]
}

upsert_env_key() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local tmp_file="${env_file}.tmp.$$"

  if [[ ! -f "${env_file}" ]]; then
    printf "%s=%s\n" "${key}" "${value}" > "${env_file}"
    return
  fi

  awk -v key="${key}" -v value="${value}" '
    BEGIN { replaced = 0 }
    index($0, key "=") == 1 {
      if (replaced == 0) {
        print key "=" value
        replaced = 1
      }
      next
    }
    { print }
    END {
      if (replaced == 0) {
        print key "=" value
      }
    }
  ' "${env_file}" > "${tmp_file}"

  mv "${tmp_file}" "${env_file}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url)
      REPO_URL="${2:-}"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="${2:-}"
      shift 2
      ;;
    --app-path)
      APP_BUNDLE_PATH="${2:-}"
      shift 2
      ;;
    --branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    --cli-bin-dir)
      CLI_BIN_DIR="${2:-}"
      shift 2
      ;;
    --no-launch)
      LAUNCH_AFTER_INSTALL=0
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

if [[ -z "${REPO_URL}" || -z "${INSTALL_DIR}" || -z "${APP_BUNDLE_PATH}" || -z "${BRANCH}" || -z "${CLI_BIN_DIR}" ]]; then
  echo "error: invalid empty argument." >&2
  exit 1
fi

mkdir -p "$(dirname "${INSTALL_DIR}")"
mkdir -p "$(dirname "${APP_BUNDLE_PATH}")"
mkdir -p "${HOME}/.agent-context"
mkdir -p "${CLI_BIN_DIR}"

if [[ -d "${INSTALL_DIR}/.git" ]]; then
  if ! is_repo_root "${INSTALL_DIR}"; then
    echo "error: ${INSTALL_DIR} is a git checkout but not an agent-context repository root." >&2
    exit 1
  fi

  if [[ -n "$(git -C "${INSTALL_DIR}" status --porcelain)" ]]; then
    echo "error: ${INSTALL_DIR} has uncommitted changes. Commit/stash before reinstall/update." >&2
    exit 1
  fi

  echo "Updating existing checkout at ${INSTALL_DIR}..."
  git -C "${INSTALL_DIR}" fetch --quiet origin "${BRANCH}"
  if [[ "$(git -C "${INSTALL_DIR}" rev-parse --abbrev-ref HEAD)" != "${BRANCH}" ]]; then
    if git -C "${INSTALL_DIR}" show-ref --verify --quiet "refs/heads/${BRANCH}"; then
      git -C "${INSTALL_DIR}" checkout "${BRANCH}"
    else
      git -C "${INSTALL_DIR}" checkout -b "${BRANCH}" "origin/${BRANCH}"
    fi
  fi
  git -C "${INSTALL_DIR}" pull --ff-only origin "${BRANCH}"
else
  if [[ -e "${INSTALL_DIR}" ]]; then
    echo "error: ${INSTALL_DIR} exists and is not a git checkout." >&2
    exit 1
  fi

  echo "Cloning ${REPO_URL} into ${INSTALL_DIR}..."
  git clone --branch "${BRANCH}" "${REPO_URL}" "${INSTALL_DIR}"
fi

echo "Building app bundle..."
"${INSTALL_DIR}/scripts/build_macos_app.sh" "${APP_BUNDLE_PATH}"

CLI_TARGET="${INSTALL_DIR}/.build/release/agent-context"
CLI_LINK="${CLI_BIN_DIR}/agent-context"
if [[ -x "${CLI_TARGET}" ]]; then
  ln -sf "${CLI_TARGET}" "${CLI_LINK}"
fi

ENV_FILE="${HOME}/.agent-context/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  cat > "${ENV_FILE}" <<'ENV'
# Agent Context local configuration
# OPENROUTER_API_KEY=your_key_here
# AGENT_CONTEXT_OPENROUTER_MODEL=google/gemini-3.1-flash-lite-preview
ENV
fi

upsert_env_key "${ENV_FILE}" "AGENT_CONTEXT_REPO_ROOT" "${INSTALL_DIR}"

echo ""
echo "Installed Agent Context."
echo "Repo: ${INSTALL_DIR}"
echo "App:  ${APP_BUNDLE_PATH}"
echo "CLI:  ${CLI_LINK}"
echo "Env:  ${ENV_FILE}"
echo ""
echo "If needed, add CLI to PATH:"
echo "  export PATH=\"${CLI_BIN_DIR}:\$PATH\""
echo ""
echo "Update later with:"
echo "  ${INSTALL_DIR}/scripts/update.sh --apply"

if [[ "${LAUNCH_AFTER_INSTALL}" -eq 1 ]]; then
  open -n "${APP_BUNDLE_PATH}"
fi
