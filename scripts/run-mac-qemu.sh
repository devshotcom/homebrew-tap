#!/bin/bash
# DevShot Cell — Native Mac QEMU/HVF launcher (spec 038)
# Runs pool VMs as direct QEMU/HVF subprocesses. No Xen, no Docker.
# Zero nesting — fastest path on Apple Silicon.
#
# Requirements:
#   - macOS on Apple Silicon (M1-M5+)
#   - QEMU installed: brew install qemu
#   - Build artifacts in .build/ (run: make build)
#
# Usage:
#   DEVSHOT_SERVER_ID=xxx DEVSHOT_HMAC_SECRET=yyy ./run-mac-qemu.sh
#   # or via Homebrew:
#   brew install anticipatercom/tap/devshot && devshot run
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build"

# ── Refuse sudo ────────────────────────────────────────────────────────────
if [ "$(id -u)" = "0" ]; then
  echo "ERROR: Do not run devshot as root / via sudo."
  echo "  DevShot on Mac does not need root. User-mode networking + HVF work"
  echo "  without elevated privileges. Running as root weakens the sandbox."
  exit 1
fi

# ── Validate requirements ───────────────────────────────────────────────────
if ! command -v qemu-system-aarch64 &>/dev/null; then
  echo "ERROR: qemu-system-aarch64 not found. Install with: brew install qemu"
  exit 1
fi

# Check HVF support
if ! qemu-system-aarch64 -accel help 2>&1 | grep -q hvf; then
  echo "ERROR: QEMU does not support HVF acceleration on this system."
  echo "  Ensure you are on Apple Silicon (M1+) and running a recent QEMU."
  exit 1
fi

# Check artifacts
for f in Image-domu devshot-guest-base.qcow2; do
  if [ ! -f "${BUILD_DIR}/${f}" ]; then
    echo "ERROR: Missing ${BUILD_DIR}/${f}"
    echo "  Run 'make build' first to compile artifacts."
    exit 1
  fi
done

# ── Environment ─────────────────────────────────────────────────────────────
: "${DEVSHOT_SERVER_ID:?ERROR: DEVSHOT_SERVER_ID is required. Export it or pass inline.}"
: "${DEVSHOT_HMAC_SECRET:?ERROR: DEVSHOT_HMAC_SECRET is required.}"
DEVSHOT_TUNNEL_URL="${DEVSHOT_TUNNEL_URL:-wss://console.devshot.com}"
DEVSHOT_TLS_SKIP="${DEVSHOT_TLS_SKIP:-0}"
POOL_SIZE="${POOL_SIZE:-2}"
LOG_LEVEL="${LOG_LEVEL:-info}"

# Force QEMU backend
export DEVSHOT_HYPERVISOR=qemu
export ROLE=dom0
export XS_REAL=0

# ── Working directory ───────────────────────────────────────────────────────
WORK_DIR="${BUILD_DIR}/mac-run-qemu"
mkdir -p "${WORK_DIR}/qemu" "${WORK_DIR}/guests" "${WORK_DIR}/xenstore-dom0"

export XS_ROOT="${WORK_DIR}/xenstore-dom0"

# ── Sandbox profile ────────────────────────────────────────────────────────
# Use the bundled sandbox-exec profile for per-VM sandboxing.
SANDBOX_PROFILE="${SCRIPT_DIR}/sandbox/devshot-vmm-qemu.sb"
if [ -f "$SANDBOX_PROFILE" ]; then
  export DEVSHOT_SANDBOX_PROFILE="$SANDBOX_PROFILE"
  echo "  Sandbox:    sandbox-exec profile loaded"
elif [ -f "/opt/homebrew/etc/devshot/devshot-vmm-qemu.sb" ]; then
  export DEVSHOT_SANDBOX_PROFILE="/opt/homebrew/etc/devshot/devshot-vmm-qemu.sb"
  echo "  Sandbox:    Homebrew sandbox profile loaded"
else
  echo "  WARNING: No sandbox-exec profile found. Per-VM sandboxing disabled."
  echo "  Expected at: ${SANDBOX_PROFILE}"
fi

# ── Copy artifacts to working dir ──────────────────────────────────────────
cp "${BUILD_DIR}/Image-domu" "${WORK_DIR}/Image-domu" 2>/dev/null || true
cp "${BUILD_DIR}/devshot-guest-base.qcow2" "${WORK_DIR}/devshot-guest-base.qcow2" 2>/dev/null || true

# Copy agent binary
if [ -f "${BUILD_DIR}/devshot-agent" ]; then
  cp "${BUILD_DIR}/devshot-agent" "${WORK_DIR}/agent"
  chmod +x "${WORK_DIR}/agent"
elif [ -f "${SCRIPT_DIR}/go/devshot-agent" ]; then
  cp "${SCRIPT_DIR}/go/devshot-agent" "${WORK_DIR}/agent"
  chmod +x "${WORK_DIR}/agent"
fi

# ── Status banner ──────────────────────────────────────────────────────────
CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')
TOTAL_RAM_MB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
CPU_CORES=$(sysctl -n hw.ncpu)

echo "════════════════════════════════════════════════════════"
echo "  DevShot Cell — Native Mac (QEMU/HVF, no Xen)"
echo "════════════════════════════════════════════════════════"
echo "  CPU:        ${CPU_MODEL}"
echo "  Host RAM:   ${TOTAL_RAM_MB}MB  CPUs: ${CPU_CORES}"
echo "  Server ID:  ${DEVSHOT_SERVER_ID}"
echo "  Tunnel URL: ${DEVSHOT_TUNNEL_URL}"
echo "  Pool size:  ${POOL_SIZE}"
echo "  Accel:      HVF (Apple Hypervisor.framework)"
echo "  Backend:    QEMU (direct, no Xen nesting)"
echo "  Work dir:   ${WORK_DIR}"
echo "════════════════════════════════════════════════════════"
echo ""

# ── Graceful shutdown ────────────────────────────────────────────────────────
cleanup() {
  echo ""
  echo "Shutting down..."
  [ -n "${AGENT_PID:-}" ] && kill "$AGENT_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  echo "Cell stopped."
  exit 0
}
trap cleanup TERM INT

# ── Export env for the agent ────────────────────────────────────────────────
export DEVSHOT_SERVER_ID
export DEVSHOT_HMAC_SECRET
export DEVSHOT_TUNNEL_URL
export DEVSHOT_TLS_SKIP
export POOL_SIZE
export LOG_LEVEL
export GUESTS_DIR="${WORK_DIR}/guests"
export BASE_IMAGE="${WORK_DIR}/devshot-guest-base.qcow2"
export KERNEL="${WORK_DIR}/Image-domu"
export BRIDGE=""  # No bridge on Mac; use user-mode networking
export DEVSHOT_QEMU_RUNTIME="${WORK_DIR}/qemu"

# ── Launch the Go agent directly ────────────────────────────────────────────
if [ -f "${WORK_DIR}/agent" ]; then
  echo "Starting agent (QEMU/HVF backend)..."
  "${WORK_DIR}/agent" &
  AGENT_PID=$!
  echo "  Agent started (pid=${AGENT_PID})"
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo "  Cell running natively on Mac (HVF, no Xen)"
  echo "  Accel:        HVF (Apple Hypervisor.framework)"
  echo "  Server ID:    ${DEVSHOT_SERVER_ID}"
  echo "  Tunnel:       ${DEVSHOT_TUNNEL_URL}"
  echo "  Pool size:    ${POOL_SIZE}"
  echo "════════════════════════════════════════════════════════"
  echo ""
  wait "$AGENT_PID" 2>/dev/null || {
    echo "Agent exited. Press Ctrl-C to stop."
    tail -f /dev/null
  }
else
  echo "ERROR: No agent binary found at ${WORK_DIR}/agent"
  echo "  Build with: cd apps/agent/go && go build -o ${WORK_DIR}/agent ."
  exit 1
fi
