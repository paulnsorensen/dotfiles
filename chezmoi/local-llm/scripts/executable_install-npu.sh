#!/usr/bin/env bash
# Enable the NPU worker (FastFlowLM on AMD XDNA 2).
#
# IMPORTANT: `lemonade backends install flm:npu` is Windows-only — on Linux,
# FastFlowLM must be installed from its own GitHub release as a .deb.
# Reference: https://lemonade-server.ai/flm_npu_linux.html
# Reference: https://github.com/FastFlowLM/FastFlowLM/releases
#
# Run once, then: systemctl --user start worker-npu

set -euo pipefail

FLM_VERSION="${FLM_VERSION:-0.9.43}"          # override with FLM_VERSION=x.y.z bash install-npu.sh
UBUNTU_TAG="${UBUNTU_TAG:-ubuntu26.04}"        # override if running a different Ubuntu

if [[ $EUID -eq 0 ]]; then
  echo "Do not run as root — script uses sudo where needed."
  exit 1
fi

echo "=== 1. Add Lemonade PPA (idempotent) ==="
if ! grep -rq "lemonade-team" /etc/apt/sources.list.d/ 2>/dev/null; then
  sudo add-apt-repository -y ppa:lemonade-team/stable
  sudo apt update
else
  echo "already added"
fi

echo ""
echo "=== 2. Install XRT NPU userspace (libxrt-npu2) ==="
# amdxdna kernel driver is in-tree on Linux 7.0, no DKMS needed.
sudo apt install -y libxrt-npu2

echo ""
echo "=== 3. Bump memlock limits (FastFlowLM uses pinned memory) ==="
LIMITS=/etc/security/limits.d/99-npu.conf
if ! sudo grep -q "memlock" "$LIMITS" 2>/dev/null; then
  sudo tee "$LIMITS" >/dev/null <<'EOF'
*    soft    memlock    unlimited
*    hard    memlock    unlimited
EOF
  echo "Wrote $LIMITS — re-login needed before non-root processes inherit the new limit."
else
  echo "already set"
fi

echo ""
echo "=== 4. Download + install FastFlowLM v${FLM_VERSION} for ${UBUNTU_TAG} ==="
DEB_NAME="fastflowlm_${FLM_VERSION}_${UBUNTU_TAG}_amd64.deb"
DEB_URL="https://github.com/FastFlowLM/FastFlowLM/releases/download/v${FLM_VERSION}/${DEB_NAME}"
TMP_DEB="/tmp/${DEB_NAME}"

if ! command -v flm >/dev/null 2>&1; then
  echo "Downloading from $DEB_URL"
  curl -fSL -o "$TMP_DEB" "$DEB_URL"
  sudo apt install -y "$TMP_DEB"
  rm -f "$TMP_DEB"
else
  echo "flm binary already present ($(command -v flm)) — skipping"
fi

echo ""
echo "=== 5. Verify Lemonade now sees flm:npu as installed ==="
~/local-llm/bin/lemonade/lemond --port 8000 --host 127.0.0.1 > /tmp/lemond-verify.log 2>&1 &
LEMOND_PID=$!
trap 'kill $LEMOND_PID 2>/dev/null || true' EXIT
sleep 3
~/local-llm/bin/lemonade/lemonade backends 2>&1 | grep -E "flm|Recipe" | head -3

echo ""
echo "=== 6. Pull a small NPU model (Llama-3.2-3B-Instruct via flm recipe) ==="
~/local-llm/bin/lemonade/lemonade pull Llama-3.2-3B-Instruct-GGUF --recipe flm 2>&1 | tail -10

kill $LEMOND_PID 2>/dev/null || true

echo ""
echo "=== Done ==="
echo "Enable + start the NPU worker:"
echo "  systemctl --user enable --now worker-npu"
echo ""
echo "Verify:"
echo "  curl http://127.0.0.1:8000/v1/models"
echo "  llm-chat local-classifier 'classify: hello world as greeting or other'"
echo ""
if [[ "$(ulimit -l)" != "unlimited" ]]; then
  echo "NOTE: ulimit -l = $(ulimit -l) — log out and back in for memlock=unlimited to apply"
  echo "      to your shell + any new systemd user services."
fi
