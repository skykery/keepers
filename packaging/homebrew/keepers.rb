# Homebrew cask for Keepers. Publish it in a tap repository named
# `homebrew-keepers` (github.com/skykery/homebrew-keepers, path Casks/keepers.rb),
# then: brew install --cask skykery/keepers/keepers
#
# After each release, update `version` and `sha256`:
#   shasum -a 256 Keepers-<version>.dmg
cask "keepers" do
  version "2.1.0"
  sha256 "a09e9c7cef828c14b2f34f408d35f093454336c40207c70a3cde223ce0bfabd2"

  url "https://github.com/skykery/keepers/releases/download/v#{version}/Keepers-#{version}.dmg"
  name "Keepers"
  desc "Finds the best shots in a folder of photos, on device"
  homepage "https://github.com/skykery/keepers"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "Keepers.app"

  zap trash: [
    "~/Library/Application Support/Keepers",
    "~/Library/Preferences/com.skykery.keepers.plist",
  ]
end
