class Devshot < Formula
  desc "Dev environment VMs with hardware-accelerated HVF on Mac"
  homepage "https://devshot.com"
  url "https://github.com/devshotcom/homebrew-tap/releases/download/v0.1.0/devshot-macos-arm64-qemu.tar.gz"
  sha256 "5d088e546b7f79a27a5eb84be1df0f6a63e33c63e978a8df11cecd87ea8e4108"
  license "MIT"
  version "0.1.0"

  depends_on "qemu"
  depends_on :macos
  depends_on arch: :arm64

  def install
    bin.install "run-mac-qemu.sh" => "devshot-run"
    libexec.install "devshot-agent"
    (var/"devshot").mkpath
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
          export DEVSHOT_SANDBOX_PROFILE="#{etc}/devshot/devshot-vmm-qemu.sb"
          mkdir -p "$BUILD_DIR"
          cp "#{libexec}/devshot-agent" "$BUILD_DIR/devshot-agent" 2>/dev/null || true
          cp "#{var}/devshot/Image-domu" "$BUILD_DIR/Image-domu" 2>/dev/null || true
          cp "#{var}/devshot/devshot-guest-base.qcow2" "$BUILD_DIR/devshot-guest-base.qcow2" 2>/dev/null || true
          exec "#{bin}/devshot-run" "$@"
          ;;
        version) echo "devshot #{version} (Homebrew, QEMU/HVF backend)" ;;
        *)
          echo "DevShot - dev environment VMs on Apple Silicon"
          echo ""
          echo "Usage:"
          echo "  devshot run      Start the DevShot agent with QEMU/HVF backend"
          echo "  devshot version  Show version"
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
      DevShot native Mac installer (QEMU/HVF, no Docker needed).

      To start:
        DEVSHOT_SERVER_ID=<id> DEVSHOT_HMAC_SECRET=<secret> devshot run

      Get your server ID and HMAC secret from https://console.devshot.com
    EOS
  end

  test do
    assert_match "devshot", shell_output("#{bin}/devshot version")
  end
end
