class Devshot < Formula
  desc "Dev environment VMs with hardware-accelerated HVF on Mac"
  homepage "https://devshot.com"
  url "https://github.com/devshotcom/homebrew-tap/releases/download/v0.1.0/devshot-macos-arm64-qemu.tar.gz"
  sha256 "5d088e546b7f79a27a5eb84be1df0f6a63e33c63e978a8df11cecd87ea8e4108"
  license "MIT"
  version "0.4.10"

  depends_on "qemu"
  depends_on :macos
  depends_on arch: :arm64

  def install
    bin.install "run-mac-qemu.sh" => "devshot-run"
    (var/"devshot").mkpath
    (var/"devshot").install "orchestrator-mac.qcow2"
    (var/"devshot").install "Image-domu"
    (var/"devshot").install "devshot-guest-base.qcow2"
    # Spec 047 — install the agent binary standalone in BUILD_DIR. The
    # launcher's existing 9p override loop then ships the freshly-upgraded
    # binary into the orchestrator VM at /xen/boot/agent, where the in-VM
    # init script copies it over the baked one on each OpenRC respawn.
    # That's how `brew upgrade devshot` actually reaches sharp-ada without
    # rebuilding the qcow2.
    (var/"devshot").install "devshot-agent"
    (etc/"devshot").mkpath
    (etc/"devshot").install "devshot-vmm-qemu.sb"

    (bin/"devshot").write <<~EOS
      #!/bin/bash
      # devshot CLI — Homebrew-installed dispatcher.
      # Spec 048 — autoupdate subcommand wiring; the LaunchAgent runs
      # `brew upgrade devshot` daily so the in-VM agent's `please_restart`
      # flow (spec 047) has a fresh binary to apply.
      set -u
      export PATH="#{HOMEBREW_PREFIX}/bin:$PATH"

      AUTOUPDATE_PLIST="$HOME/Library/LaunchAgents/com.devshot.autoupdate.plist"
      AUTOUPDATE_LOG="$HOME/Library/Logs/devshot-autoupdate.log"
      AUTOUPDATE_SKIP="$HOME/.devshot/autoupdate-skip"

      autoupdate_enabled() {
        # Plist exists AND launchctl knows about the label.
        [ -f "$AUTOUPDATE_PLIST" ] && launchctl list com.devshot.autoupdate >/dev/null 2>&1
      }

      autoupdate_minute() {
        # Read the existing scheduled minute from the plist, or pick a fresh
        # random one. Stagger across the hour so a 100-Mac fleet doesn't
        # hammer Homebrew/GitHub at the same wall-clock second.
        if [ -f "$AUTOUPDATE_PLIST" ]; then
          /usr/libexec/PlistBuddy -c 'Print :StartCalendarInterval:Minute' "$AUTOUPDATE_PLIST" 2>/dev/null && return
        fi
        echo $(( RANDOM % 60 ))
      }

      autoupdate_enable() {
        local minute
        minute="$(autoupdate_minute)"
        mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$HOME/.devshot"
        # Remove the skip marker if present — explicit enable overrides.
        rm -f "$AUTOUPDATE_SKIP"
        cat > "$AUTOUPDATE_PLIST" <<PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key><string>com.devshot.autoupdate</string>
        <key>ProgramArguments</key>
        <array>
          <string>/bin/bash</string>
          <string>-lc</string>
          <string>brew upgrade devshot 2>&amp;1 | /usr/bin/logger -t devshot-autoupdate</string>
        </array>
        <key>StartCalendarInterval</key>
        <dict>
          <key>Hour</key><integer>3</integer>
          <key>Minute</key><integer>${minute}</integer>
        </dict>
        <key>StandardOutPath</key><string>${AUTOUPDATE_LOG}</string>
        <key>StandardErrorPath</key><string>${AUTOUPDATE_LOG}</string>
        <key>RunAtLoad</key><false/>
      </dict>
      </plist>
      PLIST
        # bootstrap is the modern equivalent of `launchctl load`. Fall back to
        # `load` for older macOS that doesn't accept bootstrap on a user agent.
        launchctl bootstrap "gui/$(id -u)" "$AUTOUPDATE_PLIST" 2>/dev/null \
          || launchctl load "$AUTOUPDATE_PLIST" 2>/dev/null \
          || true
        echo "devshot autoupdate enabled — runs daily at 03:${minute} local time"
      }

      autoupdate_disable() {
        if [ -f "$AUTOUPDATE_PLIST" ]; then
          launchctl bootout "gui/$(id -u)/com.devshot.autoupdate" 2>/dev/null \
            || launchctl unload "$AUTOUPDATE_PLIST" 2>/dev/null \
            || true
          rm -f "$AUTOUPDATE_PLIST"
        fi
        # Persist user intent so the first-run prompt doesn't return on next `devshot run`.
        mkdir -p "$HOME/.devshot"
        : > "$AUTOUPDATE_SKIP"
        echo "devshot autoupdate disabled"
      }

      autoupdate_status() {
        if autoupdate_enabled; then
          local minute
          minute="$(autoupdate_minute)"
          echo "Auto-update: ENABLED (daily at 03:${minute} local time)"
        elif [ -f "$AUTOUPDATE_SKIP" ]; then
          echo "Auto-update: disabled (user opted out)"
        else
          echo "Auto-update: not configured (run \\\`devshot autoupdate enable\\\` to enable)"
        fi
        if [ -f "$AUTOUPDATE_LOG" ]; then
          local last_line
          last_line="$(tail -n 1 "$AUTOUPDATE_LOG" 2>/dev/null || true)"
          if [ -n "$last_line" ]; then
            echo "Last log line: $last_line"
          fi
        fi
      }

      autoupdate_now() {
        echo "Running brew upgrade devshot..."
        brew upgrade devshot
      }

      case "${1:-help}" in
        run)
          shift
          export BUILD_DIR="#{var}/devshot"
          mkdir -p "$BUILD_DIR"
          exec "#{bin}/devshot-run" "$@"
          ;;
        autoupdate)
          shift
          case "${1:-status}" in
            enable)  autoupdate_enable ;;
            disable) autoupdate_disable ;;
            status)  autoupdate_status ;;
            now)     autoupdate_now ;;
            *)
              echo "Usage: devshot autoupdate {enable|disable|status|now}"
              exit 2
              ;;
          esac
          ;;
        version) echo "devshot #{version} (Homebrew, sandboxed Alpine orchestrator)" ;;
        *)
          echo "DevShot - sandboxed dev environment VMs on Apple Silicon"
          echo ""
          echo "Usage:"
          echo "  devshot run                 Start the sandboxed orchestrator VM"
          echo "  devshot autoupdate <cmd>    Manage daily brew upgrade (enable|disable|status|now)"
          echo "  devshot version             Show version"
          echo ""
          echo "The agent runs INSIDE a sandboxed Alpine VM (not on the Mac host)."
          echo "Pool VMs spawn as nested QEMU instances inside the orchestrator."
          echo ""
          echo "Required env vars:"
          echo "  DEVSHOT_SERVER_ID    Your server ID from console.devshot.com"
          echo "  DEVSHOT_HMAC_SECRET  Your HMAC secret from console.devshot.com"
          ;;
      esac
    EOS
    chmod 0755, bin/"devshot"
  end

  def caveats
    <<~EOS
      DevShot sandboxed Mac installer (QEMU/HVF orchestrator VM).

      The agent runs inside an Alpine Linux VM with ClamAV + YARA.
      Pool VMs spawn as nested QEMU instances inside the orchestrator.
      No code runs directly on the Mac host.

      To start:
        DEVSHOT_SERVER_ID=<id> DEVSHOT_HMAC_SECRET=<secret> devshot run

      Get your server ID and HMAC secret from https://console.devshot.com

      Auto-update (spec 048): the first interactive `devshot run` asks
      whether to enable a daily LaunchAgent that runs `brew upgrade
      devshot`. Configure manually any time:

        devshot autoupdate enable    # daily at 03:NN local time
        devshot autoupdate disable
        devshot autoupdate status
    EOS
  end

  test do
    assert_match "devshot", shell_output("#{bin}/devshot version")
  end
end
