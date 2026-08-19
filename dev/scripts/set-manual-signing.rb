#!/usr/bin/env ruby
# Flips the app and widget targets' Release configurations to manual
# distribution signing. Run in the CI checkout before archiving (never
# committed): automatic signing at archive time signs with a development
# certificate, and a fresh runner has no key for an existing one, so every
# run minted a new cert until the account hit its certificate limit. The
# overrides can't go on the xcodebuild command line because they would also
# apply to SPM package targets, which reject explicitly specified
# provisioning profiles.
PBXPROJ = File.expand_path("../../Actuali/Actuali.xcodeproj/project.pbxproj", __dir__)

# One App Store profile per signed bundle; names must match the profiles in
# App Store Connect and the mapping in dev/exportOptions.plist.
PROFILES = {
  "com.mfazz.ActualiOS" => "Actuali App Store",
  "com.mfazz.ActualiOS.Widgets" => "Actuali Widgets App Store",
}

src = File.read(PBXPROJ)

PROFILES.each do |bundle_id, profile_name|
  # The target's Release XCBuildConfiguration: the only Release-named block
  # whose buildSettings carry this exact bundle identifier (the trailing
  # semicolon keeps com.mfazz.ActualiOS from matching the widget's id).
  # buildSettings blocks contain no nested braces, so [^}] safely spans one.
  release = /=\ \{\s*
      isa\ =\ XCBuildConfiguration;\s*
      buildSettings\ =\ \{[^}]*PRODUCT_BUNDLE_IDENTIFIER\ =\ #{Regexp.escape(bundle_id)};[^}]*\};\s*
      name\ =\ Release;/mx

  abort "Release configuration for #{bundle_id} not found in #{PBXPROJ}" unless src =~ release

  src = src.sub(release) do |block|
    unless block.include?("CODE_SIGN_STYLE = Automatic;")
      abort "Expected CODE_SIGN_STYLE = Automatic in the #{bundle_id} Release configuration"
    end
    block.sub("CODE_SIGN_STYLE = Automatic;", <<~SETTINGS.strip)
      CODE_SIGN_IDENTITY = "Apple Distribution";
      \t\t\t\tCODE_SIGN_STYLE = Manual;
      \t\t\t\tPROVISIONING_PROFILE_SPECIFIER = "#{profile_name}";
    SETTINGS
  end

  puts "#{bundle_id}: Release signing set to manual (Apple Distribution / #{profile_name})"
end

File.write(PBXPROJ, src)
