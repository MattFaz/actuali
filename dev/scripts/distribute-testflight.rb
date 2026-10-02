#!/usr/bin/env ruby
# Distributes the newest processed iOS build to an existing external group.
# Needs TESTFLIGHT_GROUP_NAME and ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH.
# Notes use merge subjects (PR titles) since the group's previous build;
# with no mapped previous build, only the latest build's merge is listed.
require "json"
require "net/http"
require "open3"
require_relative "asc_jwt"

class TestFlightDistribution
  APP_ID = "6764063765"

  def request(method, path, payload = nil)
    uri = URI("https://api.appstoreconnect.apple.com/v1/#{path}")
    req = Net::HTTP.const_get(method.capitalize).new(uri)
    req["Authorization"] = "Bearer #{asc_jwt}"
    if payload
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(payload)
    end
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 60) { |http| http.request(req) }
    raise "ASC #{method} #{uri.path} returned #{res.code}: #{res.body.to_s[0, 500]}" unless res.code.start_with?("2")

    res.body.to_s.empty? ? {} : JSON.parse(res.body)
  end

  def list(path, params = {})
    page = request("get", "#{path}?#{URI.encode_www_form(params.merge('limit' => 200))}")
    data = page.fetch("data")
    while (url = page.dig("links", "next"))
      uri = URI(url)
      raise "Unexpected ASC pagination URL" unless uri.host == "api.appstoreconnect.apple.com" && uri.path.start_with?("/v1/")

      page = request("get", "#{uri.path.delete_prefix('/v1/')}?#{uri.query}")
      data.concat(page.fetch("data"))
    end
    data
  end

  def git(*args)
    out, err, status = Open3.capture3("git", *args)
    raise "git #{args.first} failed: #{err}" unless status.success?

    out.strip
  end

  def commit_for_build(version)
    count = Integer(version, 10) - 100
    return nil unless count.positive?

    # Walk main's history: historical merge commits make HEAD~N arithmetic
    # incorrect. Each count includes the same ancestors as the Xcode stamp.
    git("rev-list", "--first-parent", "HEAD").lines.each do |line|
      sha = line.strip
      ancestors = git("rev-list", "--count", sha).to_i
      return sha if ancestors == count
      break if ancestors < count
    end
    nil
  end

  def notes(version, previous_version)
    finish = commit_for_build(version)
    raise "No main commit matches build #{version}; refusing to distribute an off-main build" unless finish

    start = previous_version && commit_for_build(previous_version)
    if previous_version && !start
      puts "Previous build #{previous_version} has no main commit; listing the latest merge only."
    end
    start ||= git("rev-parse", "#{finish}^")
    titles = git("log", "--first-parent", "--reverse", "--format=%s", "#{start}..#{finish}").lines.map do |line|
      "• #{line.strip.sub(/\s+\(#\d+\)\z/, '')}"
    end.uniq
    raise "No changes found for build #{version}" if titles.empty?

    text = titles.join("\n")
    text.length > 4000 ? "#{text[0, 3999]}…" : text
  end

  def run(group_name)
    raise "Set TESTFLIGHT_GROUP_NAME to the external group's name" if group_name.to_s.strip.empty?

    groups = list("betaGroups", "filter[app]" => APP_ID, "filter[name]" => group_name,
                                "filter[isInternalGroup]" => "false")
    groups.select! { |g| g.dig("attributes", "name") == group_name && g.dig("attributes", "isInternalGroup") == false }
    raise "Expected one external group named #{group_name.inspect}, found #{groups.size}" unless groups.size == 1

    group_id = groups.first.fetch("id")
    # Query only the latest valid upload; pagination isn't needed for limit=1.
    build = request("get", "builds?#{URI.encode_www_form('filter[app]' => APP_ID,
      'filter[processingState]' => 'VALID', 'filter[expired]' => 'false',
      'filter[buildAudienceType]' => 'APP_STORE_ELIGIBLE', 'filter[preReleaseVersion.platform]' => 'IOS',
      'sort' => '-uploadedDate', 'limit' => 1)}").fetch("data").first
    unless build
      puts "No processed builds available."
      return
    end
    id = build.fetch("id")
    version = build.fetch("attributes").fetch("version")
    group_builds = list("builds", "filter[app]" => APP_ID, "filter[betaGroups]" => group_id,
                                 "filter[preReleaseVersion.platform]" => "IOS")
    assigned = group_builds.any? { |b| b["id"] == id }
    previous = group_builds.reject { |b| b["id"] == id }.max_by { |b| Integer(b.fetch("attributes").fetch("version"), 10) }
    previous_version = previous&.dig("attributes", "version")
    if previous_version && Integer(previous_version, 10) >= Integer(version, 10)
      puts "Group already has a newer build."
      return
    end

    detail = request("get", "builds/#{id}/buildBetaDetail").fetch("data")
    state = detail.fetch("attributes").fetch("externalBuildState")
    if state == "IN_EXPORT_COMPLIANCE_REVIEW"
      puts "Build #{version} is awaiting export-compliance review; retry next night."
      return
    end
    allowed = %w[READY_FOR_BETA_SUBMISSION WAITING_FOR_BETA_REVIEW IN_BETA_REVIEW BETA_APPROVED READY_FOR_BETA_TESTING IN_BETA_TESTING]
    raise "Build #{version} cannot be distributed: #{state}" unless allowed.include?(state)

    if assigned && state != "READY_FOR_BETA_SUBMISSION"
      puts "Build #{version} already assigned (#{state})."
      return
    end
    if state == "READY_FOR_BETA_SUBMISSION"
      prerelease = request("get", "builds/#{id}/preReleaseVersion").fetch("data").fetch("id")
      pending = list("builds", "filter[app]" => APP_ID, "filter[preReleaseVersion]" => prerelease,
                               "filter[betaAppReviewSubmission.betaReviewState]" => "WAITING_FOR_REVIEW,IN_REVIEW")
      unless pending.empty?
        puts "Another build of this version is in beta review; retry next night."
        return
      end
    end

    whats_new = notes(version, previous_version)
    localizations = list("builds/#{id}/betaBuildLocalizations")
    english = localizations.find { |l| l.dig("attributes", "locale") == "en-US" }
    data = { type: "betaBuildLocalizations", attributes: { whatsNew: whats_new } }
    if english
      request("patch", "betaBuildLocalizations/#{english.fetch('id')}", data: data.merge(id: english.fetch("id")))
    else
      data[:attributes][:locale] = "en-US"
      data[:relationships] = { build: { data: { type: "builds", id: id } } }
      request("post", "betaBuildLocalizations", data: data)
    end
    request("patch", "buildBetaDetails/#{detail.fetch('id')}", data: {
      type: "buildBetaDetails", id: detail.fetch("id"), attributes: { autoNotifyEnabled: true },
    })
    unless assigned
      request("post", "betaGroups/#{group_id}/relationships/builds", data: [{ type: "builds", id: id }])
    end
    if state == "READY_FOR_BETA_SUBMISSION"
      request("post", "betaAppReviewSubmissions", data: {
        type: "betaAppReviewSubmissions", relationships: { build: { data: { type: "builds", id: id } } },
      })
    end
    puts "Assigned build #{version} to #{group_name}; testers will be notified after approval.\n#{whats_new}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    TestFlightDistribution.new.run(ENV["TESTFLIGHT_GROUP_NAME"])
  rescue StandardError => e
    abort e.message
  end
end
