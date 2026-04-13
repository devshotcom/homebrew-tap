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
BUILD_DIR="${BUILD_DIR:-${SCRIPT_DIR}/.build}"

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

# ── Copy boot artifacts to working dir ─────────────────────────────────────
# Pool VM kernel + base image go into boot/ (shared with orchestrator via 9p)
BOOT_DIR="${WORK_DIR}/boot"
mkdir -p "${BOOT_DIR}"
cp "${BUILD_DIR}/Image-domu" "${BOOT_DIR}/Image-domu" 2>/dev/null || true
cp "${BUILD_DIR}/devshot-guest-base.qcow2" "${BOOT_DIR}/devshot-guest-base.qcow2" 2>/dev/null || true

# Orchestrator qcow2 image (Alpine + agent + QEMU + ClamAV + YARA)
ORCH_BASE="${BUILD_DIR}/orchestrator-mac.qcow2"
ORCH_DISK="${WORK_DIR}/orchestrator.qcow2"
if [ ! -f "$ORCH_BASE" ]; then
  echo "ERROR: Missing orchestrator image at ${ORCH_BASE}"
  echo "  Build with: cd apps/agent && docker buildx build --platform linux/arm64 \\"
  echo "    -f docker/Dockerfile.orchestrator-mac -o type=local,dest=.build/orchestrator ."
  exit 1
fi
# Create CoW overlay so the base image stays clean across restarts
if [ ! -f "$ORCH_DISK" ]; then
  qemu-img create -f qcow2 -b "$ORCH_BASE" -F qcow2 "$ORCH_DISK"
fi

# ── Orchestrator VM sizing ─────────────────────────────────────────────────
CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')
TOTAL_RAM_MB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
CPU_CORES=$(sysctl -n hw.ncpu)
# Give the orchestrator VM 75% of host RAM (capped at 16GB), leave rest for host
ORCH_RAM_MB=$(( TOTAL_RAM_MB * 3 / 4 ))
[ "$ORCH_RAM_MB" -gt 16384 ] && ORCH_RAM_MB=16384
[ "$ORCH_RAM_MB" -lt 2048 ] && ORCH_RAM_MB=2048
# Give 75% of host CPUs (min 2)
ORCH_CPUS=$(( CPU_CORES * 3 / 4 ))
[ "$ORCH_CPUS" -lt 2 ] && ORCH_CPUS=2

echo "════════════════════════════════════════════════════════"
echo "  DevShot Cell — Mac Sandboxed Orchestrator (HVF)"
echo "════════════════════════════════════════════════════════"
echo "  CPU:        ${CPU_MODEL}"
echo "  Host RAM:   ${TOTAL_RAM_MB}MB  CPUs: ${CPU_CORES}"
echo "  Orch RAM:   ${ORCH_RAM_MB}MB   CPUs: ${ORCH_CPUS}"
echo "  Server ID:  ${DEVSHOT_SERVER_ID}"
echo "  Tunnel URL: ${DEVSHOT_TUNNEL_URL}"
echo "  Pool size:  ${POOL_SIZE}"
echo "  Accel:      HVF (Apple Hypervisor.framework)"
echo "  Backend:    Sandboxed Alpine VM → nested QEMU pool VMs"
echo "  Work dir:   ${WORK_DIR}"
echo "════════════════════════════════════════════════════════"
echo ""

# ── Write agent environment to a file (shared via 9p) ──────────────────────
cat > "${BOOT_DIR}/agent.env" <<ENVEOF
DEVSHOT_SERVER_ID=${DEVSHOT_SERVER_ID}
DEVSHOT_HMAC_SECRET=${DEVSHOT_HMAC_SECRET}
DEVSHOT_TUNNEL_URL=${DEVSHOT_TUNNEL_URL}
DEVSHOT_TLS_SKIP=${DEVSHOT_TLS_SKIP}
POOL_SIZE=${POOL_SIZE}
LOG_LEVEL=${LOG_LEVEL}
WEBRTC_STUN_URL=${WEBRTC_STUN_URL:-stun:stun.cloudflare.com:3478}
WEBRTC_TURN_URL=${WEBRTC_TURN_URL:-}
WEBRTC_TURN_SECRET=${WEBRTC_TURN_SECRET:-}
ENVEOF
chmod 600 "${BOOT_DIR}/agent.env"

# ── Graceful shutdown ────────────────────────────────────────────────────────
cleanup() {
  echo ""
  echo "Shutting down orchestrator VM..."
  [ -n "${ORCH_PID:-}" ] && kill "$ORCH_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  echo "Cell stopped."
  exit 0
}
trap cleanup TERM INT

# ── Launch the orchestrator QEMU VM ────────────────────────────────────────
# The agent runs INSIDE this VM (Alpine + QEMU + ClamAV + YARA).
# Pool VMs are nested QEMU processes inside the orchestrator VM.
# Boot artifacts (kernel, base image) are shared from host via virtio-9p.
echo "Starting orchestrator VM (Alpine + agent + QEMU + ClamAV + YARA)..."

qemu-system-aarch64 \
  -accel hvf \
  -machine virt,gic-version=3 \
  -cpu host \
  -smp "${ORCH_CPUS}" \
  -m "${ORCH_RAM_MB}" \
  -display none \
  -kernel "${BOOT_DIR}/Image-domu" \
  -append "root=/dev/vda rw console=ttyAMA0" \
  -drive "file=${ORCH_DISK},format=qcow2,if=none,id=hd0" \
  -device virtio-blk-device,drive=hd0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-device,netdev=net0 \
  -fsdev "local,id=boot_fs,path=${BOOT_DIR},security_model=none" \
  -device virtio-9p-device,fsdev=boot_fs,mount_tag=devshot_boot \
  -chardev "socket,id=s0,path=${WORK_DIR}/orch-console.sock,server=on,wait=off" \
  -serial chardev:s0 \
  -chardev "socket,id=qmp0,path=${WORK_DIR}/orch-monitor.sock,server=on,wait=off" \
  -mon chardev=qmp0,mode=control \
  -pidfile "${WORK_DIR}/orch.pid" \
  -daemonize

ORCH_PID=$(cat "${WORK_DIR}/orch.pid" 2>/dev/null)
echo "  Orchestrator VM started (pid=${ORCH_PID})"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Cell running in sandboxed Alpine VM (HVF)"
echo "  Accel:       HVF (Apple Hypervisor.framework)"
echo "  Server ID:   ${DEVSHOT_SERVER_ID}"
echo "  Tunnel:      ${DEVSHOT_TUNNEL_URL}"
echo "  Pool size:   ${POOL_SIZE}"
echo "  SSH:         ssh root@localhost -p 2222"
echo "  Console:     socat - UNIX:${WORK_DIR}/orch-console.sock"
echo "════════════════════════════════════════════════════════"
echo ""

# Wait for the orchestrator VM process
wait "$ORCH_PID" 2>/dev/null || {
  echo "Orchestrator VM exited. Press Ctrl-C to stop."
  tail -f /dev/null
}
