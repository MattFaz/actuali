#!/usr/bin/env ruby
# Downloads the App Store provisioning profile from App Store Connect and
# installs it where xcodebuild looks up profiles for manually-signed exports.
# Auth: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to the .p8); optional
# PROFILE_NAME (defaults to "Actuali App Store").
require "base64"
require "json"
require "net/http"
require "fileutils"
require_relative "asc_jwt"

profile_name = ENV.fetch("PROFILE_NAME", "Actuali App Store")
jwt = asc_jwt

uri = URI("https://api.appstoreconnect.apple.com/v1/profiles?" \
          "filter[profileType]=IOS_APP_STORE" \
          "&filter[name]=#{URI.encode_www_form_component(profile_name)}" \
          "&fields[profiles]=name,profileContent,uuid,profileState")
res = Net::HTTP.get_response(uri, { "Authorization" => "Bearer #{jwt}" })
abort "ASC API returned #{res.code}: #{res.body[0, 500]}" unless res.code == "200"

profile = JSON.parse(res.body)["data"].find { |p| p.dig("attributes", "profileState") == "ACTIVE" }
abort "No ACTIVE profile named '#{profile_name}' found" unless profile

content = Base64.decode64(profile.dig("attributes", "profileContent"))
uuid = profile.dig("attributes", "uuid")

# Xcode 16+ reads the UserData location; older tooling reads MobileDevice.
["~/Library/MobileDevice/Provisioning Profiles",
 "~/Library/Developer/Xcode/UserData/Provisioning Profiles"].each do |dir|
  dir = File.expand_path(dir)
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "#{uuid}.mobileprovision"), content)
end
puts "Installed profile '#{profile_name}' (#{uuid})"
