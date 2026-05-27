#!/usr/bin/env python3
from __future__ import annotations

import re
from collections import OrderedDict
from pathlib import Path

import yaml


ROOT_DIR = Path(__file__).resolve().parents[1]
ACTION_FILE = ROOT_DIR / "action.yml"
OUTPUT_FILE = ROOT_DIR / "docs/reference/action-inputs-outputs.md"

# Matches indented value lines like "  public-app   Description text here"
_VALUE_LINE_RE = re.compile(r"^\s{2,}(\S+)\s{2,}(.+)$")

# Ordered input groups: (section title, [input names])
INPUT_GROUPS: list[tuple[str, list[str]]] = [
  ("Core", [
    "mode",
    "environment",
    "environments",
    "prerelease-identifiers",
    "tag-prefix",
  ]),
  ("Versioning tool", [
    "versioning-tool",
    "create-release",
    "changelog",
    "working-directory",
    "force-bump",
    "version-override",
  ]),
  ("Deployment model", [
    "deployment-model",
    "branch-map",
    "promote-branch-prefix",
    "promote-target-branch",
    "create-promotion-pr",
  ]),
  ("Authentication", [
    "auth-mode",
    "github-token",
    "app-id",
    "app-private-key",
    "submodules",
    "token-broker-url",
    "oidc-audience",
  ]),
  ("Docker", [
    "image_name",
    "bake_file",
    "bake_target",
    "registry",
    "registry-username",
    "registry-password",
    "platforms",
  ]),
  ("CI checks", [
    "enforce_branch_naming",
    "require-copilot-review",
    "copilot-review-freshness",
    "copilot-review-allowed-logins",
    "copilot-review-allow-login-pattern",
    "copilot-review-fail-on-unknown-identity",
    "copilot-review-ignore-drafts",
    "copilot-review-ignore-labels",
    "copilot-review-ignore-authors",
    "copilot-review-ignore-paths",
    "copilot-review-reporter",
    "copilot-review-check-name",
  ]),
  ("Version file injection", [
    "version-file",
    "version-file-json-path",
    "version-file-yaml-path",
  ]),
  ("GitHub Projects integration", [
    "aggregate-github-projects",
    "move-github-projects-on-release",
    "github-projects-target-status",
    "github-projects-move-on-environments",
  ]),
  ("Guardrails", [
    "admin-required-from",
  ]),
  ("Integrations", [
    "aggregate-clickup-tickets",
  ]),
  ("GitVersion", [
    "gitversion-spec",
    "gitversion-config",
    "gitversion-appsettings-file",
    "gitversion-appsettings-version-path",
  ]),
  ("release-please", [
    "release-please-release-type",
    "release-please-config-file",
  ]),
  ("Auto-merge", [
    "pr-number",
    "auto-merge-method",
  ]),
]


def normalize_description(value: object | None) -> str:
  if value is None:
    return ""
  lines = [line.rstrip() for line in str(value).strip().splitlines()]
  return "\n".join(lines).strip()


def inline_code(value: object) -> str:
  escaped = str(value).replace("`", "\\`")
  return f"`{escaped}`"


def render_default(value: object | None) -> str:
  if value is None:
    return "_Not set._"
  if isinstance(value, str) and value == "":
    return "`''`"
  return inline_code(value)


def _extract_allowed_values(description: str) -> tuple[str, list[tuple[str, str]]]:
  """Split a description into prose and an allowed-values table.

  Returns (prose, [(value, explanation), ...]).
  If no enumerated values are found, the table list is empty.
  """
  raw_lines = description.splitlines()
  prose_lines: list[str] = []
  value_entries: list[tuple[str, str]] = []
  collecting_values = False

  for line in raw_lines:
    m = _VALUE_LINE_RE.match(line)
    if m:
      collecting_values = True
      value_entries.append((m.group(1), m.group(2).strip()))
    else:
      if collecting_values:
        # Continuation line for the previous value description
        stripped = line.strip()
        if stripped and value_entries:
          prev_val, prev_desc = value_entries[-1]
          value_entries[-1] = (prev_val, f"{prev_desc} {stripped}")
        continue
      prose_lines.append(line)

  prose = "\n".join(prose_lines).strip()
  return prose, value_entries


def render_input(input_name: str, input_spec: dict[str, object]) -> list[str]:
  """Render a single input entry."""
  lines: list[str] = []
  required = bool(input_spec.get("required", False))
  default = input_spec.get("default")
  description = normalize_description(input_spec.get("description"))

  lines.extend(
    [
      f"### `{input_name}`",
      "",
      f"- Required: `{str(required).lower()}`",
      f"- Default: {render_default(default)}",
      "",
    ]
  )

  if not description:
    lines.extend(["_No description provided._", ""])
    return lines

  prose, allowed = _extract_allowed_values(description)

  if prose:
    lines.extend([prose, ""])

  if allowed:
    lines.extend(
      [
        "| Value | Description |",
        "|---|---|",
      ]
    )
    for val, desc in allowed:
      lines.append(f"| `{val}` | {desc} |")
    lines.append("")
  elif not prose:
    lines.extend(["_No description provided._", ""])

  return lines


def render_inputs(inputs: dict[str, dict[str, object]]) -> list[str]:
  lines = ["## Inputs", ""]

  if not inputs:
    lines.extend(["_No inputs defined._", ""])
    return lines

  # Track which inputs we've rendered so we can catch any ungrouped ones
  rendered: set[str] = set()

  for section_title, input_names in INPUT_GROUPS:
    section_inputs = [(n, inputs[n]) for n in input_names if n in inputs]
    if not section_inputs:
      continue

    lines.extend([f"### {section_title}", ""])

    for input_name, input_spec in section_inputs:
      rendered.add(input_name)
      entry = render_input(input_name, input_spec)
      # Demote ### to #### inside sections
      entry = [line.replace("### ", "#### ", 1) if line.startswith("### `") else line for line in entry]
      lines.extend(entry)

  # Render any inputs not covered by groups
  ungrouped = [n for n in inputs if n not in rendered]
  if ungrouped:
    lines.extend(["### Other", ""])
    for input_name in ungrouped:
      entry = render_input(input_name, inputs[input_name])
      entry = [line.replace("### ", "#### ", 1) if line.startswith("### `") else line for line in entry]
      lines.extend(entry)

  return lines


def render_outputs(outputs: dict[str, dict[str, object]]) -> list[str]:
  lines = ["## Outputs", ""]

  if not outputs:
    lines.extend(["_No outputs defined._", ""])
    return lines

  for output_name, output_spec in outputs.items():
    description = normalize_description(output_spec.get("description"))

    lines.extend(
      [
        f"### `{output_name}`",
        "",
      ]
    )

    if description:
      lines.extend([description, ""])
    else:
      lines.append("_No description provided._")
      lines.append("")

  return lines


def main() -> None:
  with ACTION_FILE.open(encoding="utf-8") as file:
    action_definition = yaml.safe_load(file) or {}

  inputs = action_definition.get("inputs", {})
  outputs = action_definition.get("outputs", {})

  if not isinstance(inputs, dict):
    raise ValueError("action.yml inputs must be a mapping")
  if not isinstance(outputs, dict):
    raise ValueError("action.yml outputs must be a mapping")

  lines: list[str] = [
    "# Action inputs and outputs",
    "",
    "This page is generated from `action.yml` by `scripts/generate-action-reference.py`.",
    "Do not edit this file manually.",
    "",
  ]
  lines.extend(render_inputs(inputs))
  lines.extend(render_outputs(outputs))

  OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)
  OUTPUT_FILE.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")

  relative_output = OUTPUT_FILE.relative_to(ROOT_DIR)
  print(f"Wrote {relative_output}")


if __name__ == "__main__":
  main()
