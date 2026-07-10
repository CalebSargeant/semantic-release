#!/usr/bin/env bats

# Guards on `action.yml` input defaults whose value is a contract with an
# upstream action rather than a cosmetic choice.

@test "gitversion-config defaults to empty so GitVersion.yml stays optional" {
  # Regression: the default used to be the literal 'GitVersion.yml'. That value
  # is forwarded to gittools/actions/gitversion/execute as `configFilePath`,
  # which throws "GitVersion configuration file not found at <path>" whenever
  # the path is non-empty and missing. Every gitversion repo without a
  # GitVersion.yml therefore failed — notably the `versioning-tool: auto` repos
  # resolved to gitversion from a bare *.csproj/*.sln. Empty means "let
  # GitVersion discover its own config, or run on built-in defaults".
  command -v ruby >/dev/null || skip "ruby not available"
  run ruby - <<'RUBY'
require "yaml"

doc = YAML.load_file("action.yml")
default = doc.fetch("inputs").fetch("gitversion-config").fetch("default")
abort "expected empty default, got #{default.inspect}" unless default == ""
RUBY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "Execute GitVersion forwards gitversion-config verbatim" {
  # The empty default only reaches gittools if nothing coerces it on the way —
  # e.g. a `|| 'GitVersion.yml'` fallback in the expression.
  command -v ruby >/dev/null || skip "ruby not available"
  run ruby - <<'RUBY'
require "yaml"

doc = YAML.load_file("action.yml")
step = doc.fetch("runs").fetch("steps").find { |s| s["id"] == "gitversion" }
abort "no step with id 'gitversion'" if step.nil?

actual = step.fetch("with").fetch("configFilePath")
expected = "${{ inputs.gitversion-config }}"
abort "expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
RUBY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
