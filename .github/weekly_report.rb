# frozen_string_literal: true

# Reports the weekly run in one open issue. A failed run opens it, or
# comments on it while it's open, with what each failed job hit. A run that
# passes closes it. DRY_RUN prints what it would post instead.

require "json"
require "open3"

TITLE = "Weekly Ruby compatibility check failed"
LABEL = "ruby-compat"
LEAD = "The weekly run builds riptide's tracer on every maintained Ruby and on Ruby's nightly builds, " \
       "to catch a Ruby that breaks it before it ships."
# Lines of the first error to show, test name and backtrace included.
ERROR_LINES = 15

def gh(*args)
  out, err, status = Open3.capture3("gh", *args)
  abort "gh #{args.first(2).join(" ")} failed: #{err}" unless status.success?
  out
end

def post(*args)
  return puts("gh #{args.first(2).join(" ")}\n#{args.last}\n\n") if ENV["DRY_RUN"]

  gh(*args)
end

# A job's log, without the timestamps and colors GitHub adds.
def log(job)
  gh("api", "--allow-escape-sequences", "repos/#{ENV.fetch("GH_REPO")}/actions/jobs/#{job["id"]}/logs")
    .lines.map { |line| line.chomp.sub(/\A\S+Z /, "").gsub(/\e\[[0-9;]*m/, "") }
end

# The first test error, or the lines before the step failed when no test
# got to report one.
def first_error(lines)
  start = lines.index { |line| line.match?(/\A\s+1\) (Error|Failure):/) }
  return lines[start, ERROR_LINES].take_while.with_index { |line, i| i.zero? || !line.match?(/\A\s+\d+\) (Error|Failure):/) } if start

  stop = lines.index { |line| line.start_with?("##[error]") } || lines.size
  lines[[stop - ERROR_LINES, 0].max...stop]
end

def section(job)
  lines = log(job)
  ruby = lines.find { |line| line.match?(/\Aruby \d\S* .*\[/) }
  summary = lines.reverse.find { |line| line.match?(/\A\d+ runs, \d+ assertions/) }
  step = job["steps"].find { |s| s["conclusion"] == "failure" }&.fetch("name")
  failed = ["Failed at **#{step || "an unknown step"}**", (": `#{summary}`" if summary)].join
  error = "```\n#{first_error(lines).map(&:rstrip).join("\n").strip}\n```"
  ["### #{job["name"]}", ("`#{ruby}`" if ruby), failed, error].compact.join("\n\n")
end

repo = ENV.fetch("GH_REPO")
run_url = ENV.fetch("RUN_URL")
issue = JSON.parse(gh("issue", "list", "--state", "open", "--search", "in:title \"#{TITLE}\"", "--json", "number,title"))
            .find { |found| found["title"] == TITLE }&.fetch("number")

case ENV.fetch("RESULT")
when "success"
  if issue
    post("issue", "comment", issue.to_s, "--body", "The weekly run passed: #{run_url}")
    post("issue", "close", issue.to_s, "--reason", "completed")
  end
when "failure"
  jobs = gh("api", "--paginate", "repos/#{repo}/actions/runs/#{ENV.fetch("RUN_ID")}/jobs", "--jq", ".jobs[]")
         .lines.map { |line| JSON.parse(line) }.select { |job| job["conclusion"] == "failure" && job["name"].start_with?("Ruby") }
  body = ["#{LEAD} These jobs failed.", *jobs.map { |job| section(job) }, "riptide `#{ENV.fetch("SHA")[0, 7]}` · #{run_url}"].join("\n\n")
  if issue
    post("issue", "comment", issue.to_s, "--body", body)
  else
    post("label", "create", LABEL, "--force", "--color", "B60205", "--description", "The weekly run against maintained and nightly Rubies")
    post("issue", "create", "--title", TITLE, "--label", LABEL, "--body", body)
  end
end
