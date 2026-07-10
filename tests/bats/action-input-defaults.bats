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

@test "Execute GitVersion takes configFilePath from the detect step" {
  # gittools resolves configFilePath against the workspace root (this action
  # never sets targetPath), while detection is scoped to working-directory.
  # Reading the raw input here would desync the two for a subdirectory project,
  # and would also reopen the door to a `|| 'GitVersion.yml'` fallback in the
  # expression, which is what made GitVersion.yml mandatory in the first place.
  command -v ruby >/dev/null || skip "ruby not available"
  run ruby - <<'RUBY'
require "yaml"

doc = YAML.load_file("action.yml")
step = doc.fetch("runs").fetch("steps").find { |s| s["id"] == "gitversion" }
abort "no step with id 'gitversion'" if step.nil?

actual = step.fetch("with").fetch("configFilePath")
expected = "${{ steps.resolve-tool.outputs.config }}"
abort "expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
RUBY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
