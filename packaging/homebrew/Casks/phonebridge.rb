cask "phonebridge" do
  version "1.0.0"
  sha256 "1faeffdf2c840b4bde5075505d624b05aebe0d2badf22b433d4eeed6ae64622d"

  url "https://github.com/garam918/phonebridge/releases/download/v#{version}/PhoneBridge-#{version}.dmg"
  name "PhoneBridge"
  desc "Browse and transfer files on Android devices over USB"
  homepage "https://github.com/garam918/phonebridge"

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
