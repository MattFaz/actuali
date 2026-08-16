#!/usr/bin/env ruby
# Posts App Store customer reviews newer than the last run to a Discord webhook.
# Auth: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH; plus WEBHOOK_URL.
# STATE_FILE holds the createdDate of the newest review already posted; the
# first run (no state) posts nothing and just records where we are, so turning
# this on doesn't dump the whole review history into the channel.
# BACKFILL=1 overrides that and posts every review ever left, oldest first.
require "json"
require "net/http"
require "time"
require "uri"
require_relative "asc_jwt"

APP_ID = "6764063765"
APP_URL = "https://apps.apple.com/app/actuali/id#{APP_ID}"
webhook = ENV.fetch("WEBHOOK_URL")
state_file = ENV.fetch("STATE_FILE", ".asc-reviews-state")
backfill = ENV["BACKFILL"] == "1"

# One page covers any normal poll; backfill walks the rest. The token is minted
# per request because a backfill can outlive its 10-minute lifetime.
url = "https://api.appstoreconnect.apple.com/v1/apps/#{APP_ID}/customerReviews" \
      "?sort=-createdDate&limit=#{backfill ? 200 : 50}"
reviews = []
while url
  res = Net::HTTP.get_response(URI(url), { "Authorization" => "Bearer #{asc_jwt}" })
  abort "ASC API returned #{res.code}: #{res.body[0, 500]}" unless res.code == "200"
  page = JSON.parse(res.body)
  reviews.concat(page["data"].map { |r| r["attributes"] })
  url = backfill ? page.dig("links", "next") : nil
end
reviews.sort_by! { |a| Time.iso8601(a["createdDate"]) }

if reviews.empty?
  puts "No reviews yet."
  exit
end
newest = reviews.last["createdDate"]

if backfill
  fresh = reviews
  puts "Backfill: posting all #{fresh.size} review(s)."
elsif !File.exist?(state_file)
  File.write(state_file, newest)
  puts "First run: recorded #{newest}, posted nothing."
  exit
else
  since = Time.iso8601(File.read(state_file).strip)
  fresh = reviews.select { |a| Time.iso8601(a["createdDate"]) > since }
  puts "#{fresh.size} new review(s) since #{since.iso8601}."
end

fresh.each do |a|
  rating = a["rating"].to_i
  color = rating >= 4 ? 3066993 : rating == 3 ? 16776960 : 15158332
  body = a["body"].to_s
  body = "#{body[0, 1500]}…" if body.length > 1500
  meta = ["by #{a["reviewerNickname"]}", a["territory"]].compact.join(" · ")
  payload = {
    embeds: [{
      title: "#{"⭐️" * rating}#{"☆" * (5 - rating)} #{a["title"]}"[0, 250],
      url: APP_URL,
      description: "#{body}\n\n#{meta}",
      color: color,
      timestamp: a["createdDate"],
    }],
  }
  post = Net::HTTP.post(URI(webhook), payload.to_json, "Content-Type" => "application/json")
  abort "Discord returned #{post.code}: #{post.body[0, 300]}" unless post.code.start_with?("2")
  sleep 1 # stay well under Discord's webhook rate limit
end

File.write(state_file, newest)
