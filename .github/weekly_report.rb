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
# The compiler's lines the extension's build prints when the tracer doesn't
# compile, the same ones it picks out of mkmf's log.
COMPILER_ERROR = /error|undefined|Undefined|referenced from|\A\s+"/

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

# The first test error. When no test got to report one, why the tracer
# stayed off, with the compiler's errors when it didn't build, or else the
# lines before the step failed, up to rake giving up.
def first_error(lines)
  start = lines.index { |line| line.match?(/\A\s+1\) (Error|Failure):/) }
  return lines[start, ERROR_LINES].take_while.with_index { |line, i| i.zero? || !line.match?(/\A\s+\d+\) (Error|Failure):/) } if start

  stop = lines.index { |line| line.start_with?("rake aborted!", "##[error]") } || lines.size
  off = lines[0...stop].index { |line| line.start_with?("riptide will stay off") }
  compiled = off && lines[0...off].rindex { |line| line.start_with?("riptide's tracer didn't compile:") }
  # The build's own output can land between the compiler's errors.
  return lines[(compiled || off)..off].select { |line| line.match?(COMPILER_ERROR) || line.start_with?("riptide") } + [lines[stop - 1]] if off

  lines[[stop - ERROR_LINES, 0].max...stop]
end

# What a job hit. Jobs failed the same way when they hit the same error,
# whichever test hit it first, since tests run in a different order in each.
def failure(job)
  lines = log(job)
  step = job["steps"].find { |s| s["conclusion"] == "failure" }&.fetch("name")
  summary = lines.reverse.find { |line| line.match?(/\A\d+ runs, \d+ assertions/) }
  error = first_error(lines).map(&:rstrip).join("\n").strip
  { ruby: lines.find { |line| line.match?(/\Aruby \d\S* .*\[/) }, step: step, summary: summary,
    error: error, same: error.lines.reject { |line| line.match?(/\A\S+#test_|\A\s+\S+:\d+:in /) }.join }
end

def section(jobs, found)
  failed = ["Failed at **#{found[:step] || "an unknown step"}**", (": `#{found[:summary]}`" if found[:summary])].join
  also = "The same in:\n#{jobs.drop(1).map { |name| "- #{name}" }.join("\n")}" if jobs.size > 1
  ["### #{jobs.first}", also, ("`#{found[:ruby]}`" if found[:ruby]), failed, "```\n#{found[:error]}\n```"].compact.join("\n\n")
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
  failures = jobs.to_h { |job| [job["name"], failure(job)] }
  sections = failures.group_by { |_, found| found.values_at(:ruby, :step, :summary, :same) }
                     .map { |_, same| section(same.map(&:first), same.first.last) }
  body = ["#{LEAD} These jobs failed.", *sections, "riptide `#{ENV.fetch("SHA")[0, 7]}` · #{run_url}"].join("\n\n")
  if issue
    post("issue", "comment", issue.to_s, "--body", body)
  else
    post("label", "create", LABEL, "--force", "--color", "B60205", "--description", "The weekly run against maintained and nightly Rubies")
    post("issue", "create", "--title", TITLE, "--label", LABEL, "--body", body)
  end
end
