# Mints a short-lived App Store Connect API token.
# Needs ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to the .p8).
require "openssl"
require "base64"
require "json"

def asc_jwt
  key_id = ENV.fetch("ASC_KEY_ID")
  issuer = ENV.fetch("ASC_ISSUER_ID")
  key = OpenSSL::PKey.read(File.read(File.expand_path(ENV.fetch("ASC_KEY_PATH"))))

  b64 = ->(s) { Base64.urlsafe_encode64(s).delete("=") }
  now = Time.now.to_i
  header = b64.({ alg: "ES256", kid: key_id, typ: "JWT" }.to_json)
  payload = b64.({ iss: issuer, iat: now, exp: now + 600, aud: "appstoreconnect-v1" }.to_json)
  signing_input = "#{header}.#{payload}"
  der = key.sign(OpenSSL::Digest::SHA256.new, signing_input)
  # JWT ES256 wants the raw 64-byte r||s signature, not DER.
  r, s = OpenSSL::ASN1.decode(der).value.map { |i| i.value.to_s(2).rjust(32, "\x00")[-32..] }
  "#{signing_input}.#{b64.(r + s)}"
end
