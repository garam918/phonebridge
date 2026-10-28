cask "phonebridge" do
  version "1.0.0"
  sha256 "dce53359a33362f3469d811602a54d3ceb156f420cc7c59a633e282134fcef5a"

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

  uninstall quit:      "com.phonebridge.PhoneBridge",
            launchctl: "com.phonebridge.PhoneBridge.Launcher"

  zap trash: [
    "~/Library/Containers/com.phonebridge.PhoneBridge",
    "~/Library/Containers/com.phonebridge.PhoneBridge.FinderVolume",
    "~/Library/Containers/com.phonebridge.PhoneBridge.Launcher",
    "~/Library/Group Containers/group.com.phonebridge.shared",
  ]
end
