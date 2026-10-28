cask "phonebridge" do
  version "1.0.0"
  sha256 "19e86cd03e8f60e7a19114962a3cd423d5d86342a0faa9fe80d46290bca10258"

  url "https://github.com/garam918/phonebridge/releases/download/v#{version}/PhoneBridge-#{version}.dmg"
  name "PhoneBridge"
  desc "Browse and transfer files on Android devices over USB"
  homepage "https://garam918.github.io/phonebridge/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "PhoneBridge.app"

  uninstall quit: "com.phonebridge.PhoneBridge"

  zap trash: [
    "~/Library/Containers/com.phonebridge.PhoneBridge",
    "~/Library/Containers/com.phonebridge.PhoneBridge.FinderVolume",
    "~/Library/Group Containers/group.com.phonebridge.shared",
  ]
end
