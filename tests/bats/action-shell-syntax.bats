#!/usr/bin/env bats

# actionlint+shellcheck lint the `run:` blocks of workflow files under
# .github/workflows, but NOT the embedded `run:` scripts of a composite
# action.yml. A broken-quoting bug in one of those scripts therefore ships
# silently and only blows up at runtime ("syntax error near unexpected
# token"). This guard parses every composite run block with `bash -n`.

@test "every composite run block in action.yml is valid bash" {
  command -v ruby >/dev/null || skip "ruby not available"
  run ruby - <<'RUBY'
require "open3"
require "tempfile"
require "yaml"

doc = YAML.safe_load_file("action.yml", aliases: false)
failures = []

doc.fetch("runs").fetch("steps").each do |step|
  next unless step.key?("run")
  next unless step.fetch("shell", "bash") == "bash"

  name = step.fetch("name", "<unnamed>")
  file = Tempfile.new(["diatreme-action-run", ".sh"])
  begin
    file.write(step.fetch("run"))
    file.close
    _stdout, stderr, status = Open3.capture3("bash", "-n", file.path)
    failures << "#{name}: #{stderr.strip}" unless status.success?
  ensure
    file.unlink
  end
end

unless failures.empty?
  puts failures.join("\n")
  exit 1
end
RUBY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
