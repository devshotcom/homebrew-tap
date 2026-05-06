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
# Pool size is owned by the console (servers.pool_size in DB, pushed via
# tunnel-server's config message on every dom0 connect). The agent no
# longer reads POOL_SIZE from env — see apps/agent/go/vmmanager.go.
LOG_LEVEL="${LOG_LEVEL:-info}"

# Force QEMU backend
export DEVSHOT_HYPERVISOR=qemu
export ROLE=dom0
export XS_REAL=0

# ── Spec 048 — auto-update prompt + recent-failure warning ─────────────────
# Both run only on a TTY: scripted invocations (CI, automation, supervisor
# daemons) skip the interactive bits silently.
if [ -t 0 ] && [ -t 1 ]; then
  AUTOUPDATE_PLIST="$HOME/Library/LaunchAgents/com.devshot.autoupdate.plist"
  AUTOUPDATE_LOG="$HOME/Library/Logs/devshot-autoupdate.log"
  AUTOUPDATE_SKIP="$HOME/.devshot/autoupdate-skip"

  # Failure warning first (informational; runs every interactive launch).
  if [ -f "$AUTOUPDATE_PLIST" ] && [ -f "$AUTOUPDATE_LOG" ]; then
    LAST_LOG_TS=$(stat -f '%m' "$AUTOUPDATE_LOG" 2>/dev/null || echo 0)
    NOW_TS=$(date +%s)
    AGE_DAYS=$(( (NOW_TS - LAST_LOG_TS) / 86400 ))
    LAST_LINE=$(tail -n 1 "$AUTOUPDATE_LOG" 2>/dev/null || echo "")
    if [ "$AGE_DAYS" -le 7 ] && [ -n "$LAST_LINE" ] \
       && echo "$LAST_LINE" | grep -qiE 'error|fail|cannot|not found'; then
      printf '\033[33m[autoupdate] Last attempt looks like a failure — see %s\033[0m\n' "$AUTOUPDATE_LOG" >&2
    fi
  fi

  # First-run prompt: ask once, persist user intent.
  if [ ! -f "$AUTOUPDATE_PLIST" ] && [ ! -f "$AUTOUPDATE_SKIP" ]; then
    printf '\n'
    printf 'DevShot can auto-update itself daily so the agent stays current.\n'
    printf 'It runs `brew upgrade devshot` at 03:NN local time (random NN).\n'
    printf 'The in-VM agent picks up the new binary on its next reconnect cycle.\n\n'
    printf 'Enable daily auto-update? [Y/n] '
    # Read with a 30s timeout — if the user is piping input or wandered off,
    # default to enabled (matches spec 047's auto_update_mode='auto' default).
    if read -r -t 30 ANSWER; then :; else ANSWER=""; fi
    case "${ANSWER:-y}" in
      [Yy]*|"")
        if command -v devshot >/dev/null 2>&1; then
          devshot autoupdate enable || true
        fi
        ;;
      *)
        mkdir -p "$HOME/.devshot"
        : > "$AUTOUPDATE_SKIP"
        printf 'Auto-update opt-out recorded. Re-enable any time: `devshot autoupdate enable`\n\n'
        ;;
    esac
  fi
fi

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

# Pre-baked flavored templates (n8n, flowise, desktop, …) are produced
# by `make build-templates` into ${BUILD_DIR}/mac-run-qemu/guests/templates
# and shared with the orchestrator over a separate 9p channel so they
# show up in the pool image dropdown without rebuilding the orchestrator
# qcow2. The dir must exist before QEMU launches even if it's empty —
# the 9p export refuses to start otherwise.
TEMPLATES_DIR="${WORK_DIR}/guests/templates"
mkdir -p "${TEMPLATES_DIR}"

# Ship a fresh agent binary via 9p so the orchestrator can prefer it over the
# one baked into the image — lets us iterate on the agent without rebuilding
# the orchestrator qcow2 every time (the start-orchestrator.sh init script
# checks for this file and copies it over /opt/devshot/agent on boot).
# Fall back to the legacy `devshot-agent` name for older Homebrew bottles.
for cand in "${BUILD_DIR}/devshot-agent" "${BUILD_DIR}/devshot-agent-linux-arm64"; do
  if [ -f "$cand" ]; then
    cp "$cand" "${BOOT_DIR}/agent" && chmod 755 "${BOOT_DIR}/agent"
    break
  fi
done

# Orchestrator qcow2 image (Alpine + agent + QEMU + ClamAV + YARA)
ORCH_BASE="${BUILD_DIR}/orchestrator-mac.qcow2"
ORCH_DISK="${WORK_DIR}/orchestrator.qcow2"
ORCH_STAMP="${ORCH_DISK}.base-stamp"
if [ ! -f "$ORCH_BASE" ]; then
  echo "ERROR: Missing orchestrator image at ${ORCH_BASE}"
  echo "  Build with: cd apps/agent && docker buildx build --platform linux/arm64 \\"
  echo "    -f docker/Dockerfile.orchestrator-mac -o type=local,dest=.build/orchestrator ."
  exit 1
fi
# Create CoW overlay so the base image stays clean across restarts
ORCH_BASE_SIG=$(stat -f '%m:%z' "$ORCH_BASE" 2>/dev/null || stat -c '%Y:%s' "$ORCH_BASE" 2>/dev/null || echo unknown)
ORCH_DISK_SIG=$(cat "$ORCH_STAMP" 2>/dev/null || true)
if [ ! -f "$ORCH_DISK" ] || [ "$ORCH_BASE_SIG" != "$ORCH_DISK_SIG" ]; then
  rm -f "$ORCH_DISK"
  qemu-img create -f qcow2 -b "$ORCH_BASE" -F qcow2 "$ORCH_DISK"
  printf '%s\n' "$ORCH_BASE_SIG" > "$ORCH_STAMP"
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
echo "  Pool size:  (set by console — pushed via tunnel config on connect)"
echo "  Accel:      HVF (Apple Hypervisor.framework)"
echo "  Backend:    Sandboxed Alpine VM → nested QEMU pool VMs"
echo "  Work dir:   ${WORK_DIR}"
echo "════════════════════════════════════════════════════════"
echo ""

# ── Write agent environment to a file (shared via 9p) ──────────────────────
# Inside the orchestrator QEMU guest the host is reachable via 10.0.2.2
# (QEMU user-mode networking gateway). `host.docker.internal` is a Docker
# Desktop /etc/hosts entry on the HOST and is NOT resolvable from inside
# the guest, so any callers that pass that DNS name (dev.sh defaults,
# console-pasted commands assuming Docker context) get rewritten here.
# Production tunnel URLs (wss://console.devshot.com) are untouched.
rewrite_for_qemu_guest() {
  echo "$1" | sed 's|host\.docker\.internal|10.0.2.2|g'
}
DEVSHOT_TUNNEL_URL="$(rewrite_for_qemu_guest "$DEVSHOT_TUNNEL_URL")"
AGENT_WEBRTC_STUN_URL="$(rewrite_for_qemu_guest "${WEBRTC_STUN_URL:-stun:10.0.2.2:3478}")"
AGENT_WEBRTC_TURN_URL="$(rewrite_for_qemu_guest "${WEBRTC_TURN_URL:-${WEBRTC_TURN_URL_QEMU:-${WEBRTC_TURN_URL_DOCKER:-turn:10.0.2.2:3478}}}")"

cat > "${BOOT_DIR}/agent.env" <<ENVEOF
DEVSHOT_SERVER_ID=${DEVSHOT_SERVER_ID}
DEVSHOT_HMAC_SECRET=${DEVSHOT_HMAC_SECRET}
DEVSHOT_TUNNEL_URL=${DEVSHOT_TUNNEL_URL}
DEVSHOT_TLS_SKIP=${DEVSHOT_TLS_SKIP}
# POOL_SIZE intentionally NOT written: the agent reads its pool target
# from the console's \`config\` push (servers.pool_size in the DB),
# never from env. Writing POOL_SIZE here would have no effect and
# would only mislead operators reading agent.env about the source of
# truth. See apps/agent/go/vmmanager.go for the matching code change.
LOG_LEVEL=${LOG_LEVEL}
# Nested TCG (the orchestrator runs under HVF, but pool VMs themselves
# run TCG-on-TCG since KVM isn't available inside the orchestrator).
# A vanilla 21 MiB Alpine boots in ~30s, but the desktop template adds
# ~260 MiB of packages and tigervnc + openbox + tint2 startup, which
# pushes total boot to 3-4 min. The 2 min default trips QGA WaitReady,
# the agent reports CreateVM failure, the console retry loop fires
# again and on-demand claim spawns yet another VM — runaway. Bump to
# 10 min so spawns succeed first time.
READY_TIMEOUT=${READY_TIMEOUT:-600000}
WEBRTC_STUN_URL=${AGENT_WEBRTC_STUN_URL}
WEBRTC_TURN_URL=${AGENT_WEBRTC_TURN_URL}
WEBRTC_TURN_SECRET=${WEBRTC_TURN_SECRET:-}
WEBRTC_FORCE_RELAY=${WEBRTC_FORCE_RELAY:-}
# Bakery: 9p-share the orch's apk fetch cache into bake VMs as the
# \`apk_cache\` mount tag. Recipes mount it read-only at /tmp/apkcache
# and run \`apk add --no-network --allow-untrusted /tmp/apkcache/*.apk\`
# instead of going through slirp's nested NAT (which loses big TCP
# transfers reliably — anything over ~300 KB drops with "connection
# closed prematurely"). Empty / missing dir leaves the mount off so
# production / Linux dom0 keeps its existing internet-fetch path.
BAKE_APK_CACHE_DIR=/xen/boot/apk-cache
ENVEOF
chmod 600 "${BOOT_DIR}/agent.env"

# ── Graceful shutdown ────────────────────────────────────────────────────────
cleanup() {
  echo ""
  echo "Shutting down orchestrator VM..."
  [ -n "${CLOCK_SYNC_PID:-}" ] && kill "$CLOCK_SYNC_PID" 2>/dev/null || true
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
  -fsdev "local,id=tmpl_fs,path=${TEMPLATES_DIR},security_model=none" \
  -device virtio-9p-device,fsdev=tmpl_fs,mount_tag=devshot_templates \
  -chardev "socket,id=s0,path=${WORK_DIR}/orch-console.sock,server=on,wait=off,logfile=${BOOT_DIR}/dom0-console.log,logappend=on" \
  -serial chardev:s0 \
  -chardev "socket,id=qmp0,path=${WORK_DIR}/orch-monitor.sock,server=on,wait=off" \
  -mon chardev=qmp0,mode=control \
  -device virtio-serial-device \
  -chardev "socket,id=qga0,path=${WORK_DIR}/orch-qga.sock,server=on,wait=off" \
  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  -pidfile "${WORK_DIR}/orch.pid" \
  -daemonize

ORCH_PID=$(cat "${WORK_DIR}/orch.pid" 2>/dev/null)
echo "  Orchestrator VM started (pid=${ORCH_PID})"

# ── Periodic dom0 clock sync ────────────────────────────────────────────────
# Nested QEMU clocks drift badly on Mac, especially across host sleep cycles.
# When dom0 falls more than 60 s out of sync with the host the agent's
# spec-027 client-auth freshness check (`VerifyClientResponse` ±60 s window)
# starts rejecting otherwise-valid browser responses with reason "expired",
# which surfaces in the iframe as a "channel CLOSED after 21B" proxy error.
# Push host wall time into dom0 every 30 s via QGA `guest-set-time` to keep
# drift below the threshold. The QGA socket appears as soon as dom0 boots;
# until then `nc -U` no-ops.
sync_dom0_clock() {
  local sock="${WORK_DIR}/orch-qga.sock"
  while kill -0 "$ORCH_PID" 2>/dev/null; do
    if [ -S "$sock" ]; then
      local ns="$(date -u +%s)000000000"
      ( printf '{"execute":"guest-set-time","arguments":{"time":%s}}' "$ns"; sleep 0.2 ) \
        | nc -U "$sock" >/dev/null 2>&1 || true
    fi
    sleep 30
  done
}
sync_dom0_clock &
CLOCK_SYNC_PID=$!

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Cell running in sandboxed Alpine VM (HVF)"
echo "  Accel:       HVF (Apple Hypervisor.framework)"
echo "  Server ID:   ${DEVSHOT_SERVER_ID}"
echo "  Tunnel:      ${DEVSHOT_TUNNEL_URL}"
echo "  Pool size:   (set by console — pushed via tunnel config on connect)"
echo "  SSH:         ssh root@localhost -p 2222"
echo "  Console:     socat - UNIX:${WORK_DIR}/orch-console.sock"
echo "════════════════════════════════════════════════════════"
echo ""

# qemu-system-aarch64 was daemonized, so its pid is not a waitable child of
# this shell. Poll it instead; `wait $ORCH_PID` returns immediately on macOS
# and makes a healthy VM look like it exited.
while kill -0 "$ORCH_PID" 2>/dev/null; do
  sleep 2
done

echo "Orchestrator VM exited. Press Ctrl-C to stop."
tail -f /dev/null
