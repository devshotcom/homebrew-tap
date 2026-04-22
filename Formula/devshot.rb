class Devshot < Formula
  desc "Dev environment VMs with hardware-accelerated HVF on Mac"
  homepage "https://devshot.com"
  url "https://github.com/devshotcom/homebrew-tap/releases/download/v0.3.4/devshot-macos-arm64-qemu.tar.gz"
  sha256 "2e50c312c2c5a5a2c883b0404e6ee04e925501561bcd16ebba513f1828b986b0"
  license "MIT"
  version "0.3.4"

  depends_on "qemu"
  depends_on :macos
  depends_on arch: :arm64

  def install
    bin.install "run-mac-qemu.sh" => "devshot-run"
    (var/"devshot").mkpath
    (var/"devshot").install "orchestrator-mac.qcow2"
    (var/"devshot").install "Image-domu"
    (var/"devshot").install "devshot-guest-base.qcow2"
    (etc/"devshot").mkpath
    (etc/"devshot").install "devshot-vmm-qemu.sb"

    (bin/"devshot").write <<~EOS
      #!/bin/bash
      export PATH="#{HOMEBREW_PREFIX}/bin:$PATH"
      case "${1:-help}" in
        run)
          shift
          export BUILD_DIR="#{var}/devshot"
          mkdir -p "$BUILD_DIR"
          exec "#{bin}/devshot-run" "$@"
          ;;
        version) echo "devshot #{version} (Homebrew, sandboxed Alpine orchestrator)" ;;
        *)
          echo "DevShot - sandboxed dev environment VMs on Apple Silicon"
          echo ""
          echo "Usage:"
          echo "  devshot run      Start the sandboxed orchestrator VM (Alpine + QEMU + ClamAV + YARA)"
          echo "  devshot version  Show version"
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
    EOS
  end

  test do
    assert_match "devshot", shell_output("#{bin}/devshot version")
  end
end
