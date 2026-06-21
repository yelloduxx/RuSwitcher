cask "ruswitcher" do
  version "2.2.1"
  sha256 "194af4fc9b6f62d880c55ee0be6eb7803e7be6a0256a3e1453395610c32c930f"

  url "https://github.com/rashn/RuSwitcher/releases/download/v#{version}/RuSwitcher-#{version}.dmg"
  name "RuSwitcher"
  desc "Lightweight keyboard layout switcher, free alternative to PuntoSwitcher"
  homepage "https://github.com/rashn/RuSwitcher"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :ventura

  app "RuSwitcher.app"

  zap trash: [
    "~/Library/Logs/RuSwitcher",
    "~/Library/Preferences/com.ruswitcher.app.plist",
  ]
end
