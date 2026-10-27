cask "phonebridge" do
  version "1.0.0"
  sha256 "64351a320ac810c2bc5a1081d878af661fb67a76f3dd5d20f9439b52456964de"

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
