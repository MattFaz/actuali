#!/usr/bin/env ruby
# Downloads the App Store provisioning profile from App Store Connect and
# installs it where xcodebuild looks up profiles for manually-signed exports.
# Auth: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to the .p8); optional
# PROFILE_NAME (defaults to "Actuali App Store").
require "openssl"
require "base64"
require "json"
require "net/http"
require "fileutils"

key_id = ENV.fetch("ASC_KEY_ID")
issuer = ENV.fetch("ASC_ISSUER_ID")
key_path = ENV.fetch("ASC_KEY_PATH")
profile_name = ENV.fetch("PROFILE_NAME", "Actuali App Store")

b64 = ->(s) { Base64.urlsafe_encode64(s).delete("=") }
key = OpenSSL::PKey.read(File.read(File.expand_path(key_path)))
now = Time.now.to_i
header = b64.({ alg: "ES256", kid: key_id, typ: "JWT" }.to_json)
payload = b64.({ iss: issuer, iat: now, exp: now + 600, aud: "appstoreconnect-v1" }.to_json)
signing_input = "#{header}.#{payload}"
der = key.sign(OpenSSL::Digest::SHA256.new, signing_input)
# JWT ES256 wants the raw 64-byte r||s signature, not DER.
r, s = OpenSSL::ASN1.decode(der).value.map { |i| i.value.to_s(2).rjust(32, "\x00")[-32..] }
jwt = "#{signing_input}.#{b64.(r + s)}"

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
