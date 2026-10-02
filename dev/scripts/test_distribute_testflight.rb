#!/usr/bin/env ruby
# Offline checks: no App Store Connect credentials or network requests.
require "tmpdir"
require_relative "distribute-testflight"

def check(condition, message)
  raise message unless condition
end

def raises(message)
  begin
    yield
  rescue StandardError => e
    check(e.message.include?(message), "Unexpected error: #{e.message}")
    return
  end
  raise "Expected error containing #{message.inspect}"
end

class FakeDistribution < TestFlightDistribution
  attr_accessor :state, :assigned, :previous, :pending, :english, :available, :groups
  attr_reader :writes, :notes_range

  def initialize
    @state = "READY_FOR_BETA_SUBMISSION"
    @previous = { "id" => "old", "attributes" => { "version" => "102" } }
    @groups = [{ "id" => "group", "attributes" => { "name" => "Nightly", "isInternalGroup" => false } }]
    @assigned = @pending = @english = false
    @available = true
    @writes = []
  end

  def notes(version, previous_version)
    check(@writes.empty?, "Notes must be computed before any ASC write")
    @notes_range = [version, previous_version]
    "• Fix the budget screen\n• Add account filters"
  end

  def request(method, path, payload = nil)
    unless method == "get"
      @writes << [method, path, payload]
      return {}
    end
    endpoint, query = path.split("?", 2)
    params = URI.decode_www_form(query.to_s).to_h
    build = { "id" => "new", "attributes" => { "version" => "105" } }
    data = case endpoint
           when "betaGroups" then groups
           when "builds"
             if params.key?("filter[betaGroups]")
               [previous, assigned ? build : nil].compact
             elsif params.key?("filter[betaAppReviewSubmission.betaReviewState]")
               pending ? [previous] : []
             else
               check(params["filter[processingState]"] == "VALID", "Must skip processing builds")
               check(params["filter[expired]"] == "false", "Must skip expired builds")
               check(params["filter[buildAudienceType]"] == "APP_STORE_ELIGIBLE", "Must skip internal-only builds")
               check(params["filter[preReleaseVersion.platform]"] == "IOS", "Must select iOS")
               check(params["sort"] == "-uploadedDate" && params["limit"] == "1", "Must select latest upload")
               available ? [build] : []
             end
           when "builds/new/buildBetaDetail"
             { "id" => "detail", "attributes" => { "externalBuildState" => state } }
           when "builds/new/preReleaseVersion" then { "id" => "release" }
           when "builds/new/betaBuildLocalizations"
             english ? [{ "id" => "english", "attributes" => { "locale" => "en-US" } }] : []
           else raise "Unexpected GET #{path}"
           end
    { "data" => data }
  end
end

script = FakeDistribution.new
script.run("Nightly")
check(script.notes_range == ["105", "102"], "Notes must start at the previous group build")
check(script.writes.map { |w| w[1] } == ["betaBuildLocalizations", "buildBetaDetails/detail",
  "betaGroups/group/relationships/builds", "betaAppReviewSubmissions"], "Notes and notifications must precede distribution/review")
notes = script.writes.first[2][:data]
check(notes[:attributes][:locale] == "en-US" && notes[:attributes][:whatsNew].include?("account filters"), "Missing What to Test notes")
check(notes[:relationships][:build][:data][:id] == "new", "Notes must belong to the uploaded build")
check(script.writes[1][2][:data][:attributes][:autoNotifyEnabled] == true, "Must notify testers on approval")
check(script.writes.last[2][:data][:relationships][:build][:data][:id] == "new", "Must review the selected build")

script = FakeDistribution.new
script.english = true
script.assigned = true # A prior run assigned the group, but submission failed.
script.run("Nightly")
check(script.writes.first[0..1] == ["patch", "betaBuildLocalizations/english"], "Must update existing notes")
check(script.writes.none? { |w| w[1].include?("relationships/builds") }, "Retry must not assign twice")
check(script.writes.last[1] == "betaAppReviewSubmissions", "Retry must finish the failed submission")

%w[BETA_APPROVED READY_FOR_BETA_TESTING IN_BETA_TESTING WAITING_FOR_BETA_REVIEW IN_BETA_REVIEW].each do |state|
  script = FakeDistribution.new
  script.state = state
  script.run("Nightly")
  check(script.writes.none? { |w| w[1] == "betaAppReviewSubmissions" }, "Must not resubmit #{state}")
  script = FakeDistribution.new
  script.state = state
  script.assigned = true
  script.run("Nightly")
  check(script.writes.empty?, "Already assigned #{state} should be a no-op")
end

%w[BETA_REJECTED MISSING_EXPORT_COMPLIANCE PROCESSING_EXCEPTION].each do |state|
  script = FakeDistribution.new
  script.state = state
  raises(state) { script.run("Nightly") }
  check(script.writes.empty?, "Must not mutate blocked build")
end

[false, true].each do |assigned|
  script = FakeDistribution.new
  script.state = "IN_EXPORT_COMPLIANCE_REVIEW"
  script.assigned = assigned
  script.run("Nightly")
  check(script.writes.empty?, "Export-compliance review must wait without mutating the build")
end

script = FakeDistribution.new
script.pending = true
script.run("Nightly")
check(script.writes.empty?, "Must defer while another build is in review")
script = FakeDistribution.new
script.available = false
script.run("Nightly")
check(script.writes.empty?, "No available build should be a no-op")
script = FakeDistribution.new
script.previous["attributes"]["version"] = "106"
script.run("Nightly")
check(script.writes.empty?, "Must not downgrade the group")
script = FakeDistribution.new
script.previous = nil
script.run("Nightly")
check(script.notes_range == ["105", nil], "First run should use the latest merge")
raises("TESTFLIGHT_GROUP_NAME") { FakeDistribution.new.run("") }
script = FakeDistribution.new
script.groups.first["attributes"]["isInternalGroup"] = true
raises("Expected one external group") { script.run("Nightly") }

script = TestFlightDistribution.new
pages = [{ "data" => [1], "links" => { "next" => "https://api.appstoreconnect.apple.com/v1/builds?cursor=next" } },
         { "data" => [2] }]
script.define_singleton_method(:request) { |_method, _path| pages.shift }
check(script.list("builds") == [1, 2], "Must include all pages of the group's build history")
script.define_singleton_method(:request) do |_method, _path|
  { "data" => [], "links" => { "next" => "https://example.com/v1/builds" } }
end
raises("Unexpected ASC pagination URL") { script.list("builds") }

# Real Git history checks include a merge: build count isn't a HEAD~N offset.
Dir.mktmpdir("testflight-notes") do |dir|
  Dir.chdir(dir) do
    git = TestFlightDistribution.new
    git.git("init", "-b", "main")
    git.git("config", "user.name", "Test")
    git.git("config", "user.email", "test@example.com")
    commit = ->(title) { git.git("commit", "--allow-empty", "-m", title) }
    commit.call("Initial")
    commit.call("Earlier (#1)")
    git.git("checkout", "-b", "feature")
    commit.call("Branch work")
    git.git("checkout", "main")
    commit.call("Fix the budget screen (#2)")
    git.git("merge", "--no-ff", "feature", "-m", "Add account filters (#3)")
    finish = git.git("rev-parse", "HEAD")
    commit.call("Not uploaded yet (#4)")
    check(git.commit_for_build("105") == finish, "Must map commit count through merges")
    check(git.notes("105", "102") == "• Fix the budget screen\n• Add account filters", "Must exclude old, branch, and unuploaded changes")
    check(git.notes("105", nil) == "• Add account filters", "First run must not dump full history")
    check(git.commit_for_build("104").nil?, "Must identify an unmappable build")
    check(git.commit_for_build("88").nil?, "Must identify legacy build numbering")
    check(git.notes("105", "104") == "• Add account filters", "Unmapped previous build must not block new main builds")
    check(git.notes("105", "88") == "• Add account filters", "Legacy previous build must not block new main builds")
    raises("refusing to distribute an off-main build") { git.notes("104", "102") }
    commit.call("X" * 4100)
    check(git.notes("107", "106").length == 4000, "Must respect TestFlight's notes limit")
  end
end

puts "TestFlight distribution checks passed."
