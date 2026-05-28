#!/usr/bin/env bats

# actionlint+shellcheck lint the `run:` blocks of workflow files under
# .github/workflows, but NOT the embedded `run:` scripts of a composite
# action.yml. A broken-quoting bug in one of those scripts therefore ships
# silently and only blows up at runtime ("syntax error near unexpected
# token"). This guard parses every composite run block with `bash -n`.

@test "every composite run block in action.yml is valid bash" {
  command -v python3 >/dev/null || skip "python3 not available"
  run python3 - <<'PY'
import yaml, subprocess, sys, tempfile, os
doc = yaml.safe_load(open("action.yml"))
failures = []
for step in doc["runs"]["steps"]:
    if "run" not in step:
        continue
    if step.get("shell", "bash") != "bash":
        continue
    name = step.get("name", "<unnamed>")
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as fh:
        fh.write(step["run"])
        path = fh.name
    res = subprocess.run(["bash", "-n", path], capture_output=True, text=True)
    os.unlink(path)
    if res.returncode != 0:
        failures.append(f"{name}: {res.stderr.strip()}")
if failures:
    print("\n".join(failures))
    sys.exit(1)
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
