#!/bin/bash
# Bootstrap script: installs Go (if needed) and builds the tfvar-backup binaries.
#
# Usage:
#   ./scripts/bootstrap.sh           # build only, installs to ./bin/
#   ./scripts/bootstrap.sh --install # build and install to ~/.local/bin
#
# Requirements:
#   - macOS (arm64 or amd64) or Linux (amd64 or arm64)
#   - curl, tar (standard on both platforms)
#   - AWS CLI  (https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
#   - git

set -euo pipefail

GO_VERSION="1.24.2"
INSTALL_DIR="${HOME}/.local/bin"
INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { echo "  [info]  $*"; }
ok()    { echo "  [ok]    $*"; }
die()   { echo "  [error] $*" >&2; exit 1; }

# ── Check / install Go ────────────────────────────────────────────────────────
ensure_go() {
  if command -v go &>/dev/null; then
    local ver
    ver=$(go version | awk '{print $3}' | sed 's/go//')
    info "Found Go ${ver}"
    return
  fi

  info "Go not found — installing Go ${GO_VERSION}..."

  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in
    arm64|aarch64) arch="arm64" ;;
    x86_64)        arch="amd64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac

  local tarball="go${GO_VERSION}.${os}-${arch}.tar.gz"
  local url="https://go.dev/dl/${tarball}"
  local tmp; tmp="$(mktemp -d)"

  info "Downloading ${url}..."
  curl -fsSL "${url}" -o "${tmp}/${tarball}"

  info "Extracting to /usr/local/go..."
  sudo tar -C /usr/local -xzf "${tmp}/${tarball}"
  rm -rf "${tmp}"

  export PATH="/usr/local/go/bin:${PATH}"
  ok "Go ${GO_VERSION} installed at /usr/local/go"
  echo ""
  echo "  Add Go to your PATH permanently:"
  echo "    echo 'export PATH=\"/usr/local/go/bin:\$PATH\"' >> ~/.zshrc  # or ~/.bashrc"
  echo ""
}

# ── Check AWS CLI ─────────────────────────────────────────────────────────────
check_aws() {
  if command -v aws &>/dev/null; then
    ok "AWS CLI $(aws --version 2>&1 | awk '{print $1}')"
  else
    echo ""
    echo "  [warn] AWS CLI not found."
    echo "  Install it: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
    echo ""
  fi
}

# ── Check git ─────────────────────────────────────────────────────────────────
check_git() {
  command -v git &>/dev/null || die "git is required but not found."
  ok "git $(git --version | awk '{print $3}')"
}

# ── Build ─────────────────────────────────────────────────────────────────────
build() {
  info "Building binaries..."
  cd "${REPO_ROOT}"
  make build
  ok "Binaries: ${REPO_ROOT}/bin/tfvar-backup  ${REPO_ROOT}/bin/tfvar-create-buckets"
}

# ── Install ───────────────────────────────────────────────────────────────────
install_bins() {
  mkdir -p "${INSTALL_DIR}"
  cp "${REPO_ROOT}/bin/tfvar-backup"         "${INSTALL_DIR}/"
  cp "${REPO_ROOT}/bin/tfvar-create-buckets" "${INSTALL_DIR}/"
  ok "Installed to ${INSTALL_DIR}"

  if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
    echo ""
    echo "  Add ${INSTALL_DIR} to your PATH:"
    echo "    echo 'export PATH=\"${INSTALL_DIR}:\$PATH\"' >> ~/.zshrc  # or ~/.bashrc"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo ""
echo "── tfvar-backup bootstrap ───────────────────────────────"
echo ""

ensure_go
check_aws
check_git
build

if [[ "$INSTALL" == "1" ]]; then
  install_bins
fi

echo ""
echo "✓ Done."
echo ""
echo "  Run ./bin/tfvar-backup --help"
echo "  Run ./bin/tfvar-create-buckets --help"
