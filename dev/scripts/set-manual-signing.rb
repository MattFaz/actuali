#!/usr/bin/env ruby
# Flips the app target's Release configuration to manual distribution signing.
# Run in the CI checkout before archiving (never committed): automatic signing
# at archive time signs with a development certificate, and a fresh runner has
# no key for an existing one, so every run minted a new cert until the account
# hit its certificate limit. The overrides can't go on the xcodebuild command
# line because they would also apply to SPM package targets, which reject
# explicitly specified provisioning profiles.
PBXPROJ = File.expand_path("../../Actuali/Actuali.xcodeproj/project.pbxproj", __dir__)

src = File.read(PBXPROJ)

# The app target's Release XCBuildConfiguration: the only Release-named block
# whose buildSettings carry the app bundle identifier. buildSettings blocks
# contain no nested braces, so [^}] safely spans one.
app_release = /=\ \{\s*
    isa\ =\ XCBuildConfiguration;\s*
    buildSettings\ =\ \{[^}]*PRODUCT_BUNDLE_IDENTIFIER\ =\ com\.mfazz\.ActualiOS;[^}]*\};\s*
    name\ =\ Release;/mx

abort "App Release configuration not found in #{PBXPROJ}" unless src =~ app_release

updated = src.sub(app_release) do |block|
  unless block.include?("CODE_SIGN_STYLE = Automatic;")
    abort "Expected CODE_SIGN_STYLE = Automatic in the app Release configuration"
  end
  block.sub("CODE_SIGN_STYLE = Automatic;", <<~SETTINGS.strip)
    CODE_SIGN_IDENTITY = "Apple Distribution";
    \t\t\t\tCODE_SIGN_STYLE = Manual;
    \t\t\t\tPROVISIONING_PROFILE_SPECIFIER = "Actuali App Store";
  SETTINGS
end

File.write(PBXPROJ, updated)
puts "Release signing set to manual (Apple Distribution / Actuali App Store)"
