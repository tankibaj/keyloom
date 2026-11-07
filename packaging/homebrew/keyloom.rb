# Source of truth for the tap cask. The release workflow renders @VERSION@ and @SHA256@
# and commits the result to tankibaj/homebrew-tap as Casks/keyloom.rb.
cask "keyloom" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/tankibaj/keyloom/releases/download/v#{version}/Keyloom-#{version}-arm64.zip"
  name "Keyloom"
  desc "Menu-bar text expander with snippets and tokens"
  homepage "https://github.com/tankibaj/keyloom"

  # UNVERIFIED symbol: `:tahoe` is macOS 26 in current Homebrew; confirm with `brew style`/`brew audit`.
  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "Keyloom.app"

  # The build is ad-hoc signed and not notarized: drop quarantine so Gatekeeper does not block launch.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Keyloom.app"]
  end

  zap trash: [
    "~/Library/Application Support/Keyloom",
    "~/Library/Caches/com.thenaim.keyloom",
    "~/Library/Logs/Keyloom",
    "~/Library/Preferences/com.thenaim.keyloom.plist",
  ]

  caveats <<~EOS
    Keyloom needs Accessibility access: grant it in System Settings > Privacy & Security
    on first run. After an update macOS may ask for the grant again.
  EOS
end
