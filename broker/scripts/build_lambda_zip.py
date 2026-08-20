#!/usr/bin/env python3
"""Package the broker Lambda. The ONE definition of what ships to AWS.

Used by `.github/workflows/ci.yml` (so a dependency bump that breaks the import or
blows the size budget fails on the pull request) and by `release.yml` (which publishes
the artifact). A local build and a released artifact produced by different means is a
difference nobody discovers until production behaves unlike the test.

WHAT SHIPS: `app/` minus `main.py`, plus the resolved wheels for `pyjwt[crypto]` and
`httpx`. Nothing else.

  * `app/main.py` is EXCLUDED BY NAME. It is the only module that imports FastAPI, and
    FastAPI is not in the shipped set — including it turns a working deploy into an
    ImportError at cold start on a path nobody watches.
  * `boto3`/`botocore` are never bundled. The Lambda runtime supplies them and our own
    copy would add ~50 MB.

THE OUTPUT IS DETERMINISTIC. Every entry gets a fixed timestamp and mode, and the walk
is sorted rather than whatever the filesystem returns. Without that, two builds of
identical source produce different bytes, the sha256 comparison in the release workflow
never matches, and every diatreme release opens a version-bump PR in magmamoose/infra
that redeploys the same code — exactly the noise the comparison exists to prevent.
Input determinism comes from `broker/uv.lock` via `--frozen`.

`--platform` IS REQUIRED AND HAS NO DEFAULT. `cryptography` ships compiled wheels, so a
build on a developer's macOS ARM machine would silently produce a zip that ImportErrors
inside Lambda. Making the caller name the target platform means that mistake cannot be
made by omission.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess  # nosec B404 - build tool; all argv lists are hardcoded, shell=False
import sys
import tempfile
import zipfile
from pathlib import Path

#: Fixed epoch for every entry (1980-01-01, the earliest a zip can represent).
_FIXED_DATE = (1980, 1, 1, 0, 0, 0)

#: Never shipped, whatever the resolver produces. The runtime supplies these.
_EXCLUDED_DISTRIBUTIONS = ("boto3", "botocore")

#: Imports FastAPI, which is not in the shipped dependency set.
_EXCLUDED_APP_FILES = frozenset({"main.py"})

#: Paths whose *any* component matches are skipped entirely. ``bin`` is the console
#: scripts the installer generates; nothing in Lambda can execute them and they embed
#: the build machine's absolute interpreter path, which is a reproducibility hazard as
#: well as dead weight.
_EXCLUDED_DIR_NAMES = frozenset({"__pycache__", "bin"})

#: uv's own bookkeeping in the target tree.
_EXCLUDED_NAMES = frozenset({".lock"})

#: Files that only exist to speed up a local interpreter and are not reproducible.
_EXCLUDED_SUFFIXES = (".pyc", ".pyo")

#: Anything the installer leaves behind that carries a build timestamp or an absolute
#: path from the build machine. Dropping them is what makes two builds byte-identical.
_EXCLUDED_METADATA_SUFFIXES = (".dist-info", ".egg-info")


def _run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=True, text=True, capture_output=True, **kwargs)  # nosec B603 - list argv, shell=False  # type: ignore[arg-type]


def vendor(broker_root: Path, target: Path, *, platform: str, python_version: str) -> None:
    """Resolve and install the shipped wheels into ``target``.

    Goes through `uv export --frozen` rather than reading pyproject directly, so the
    shipped set is exactly what the committed lock resolves — the same guarantee the
    lock gives CI and local development.
    """
    requirements = target.parent / "requirements.txt"
    exported = _run(
        [
            "uv",
            "export",
            "--frozen",
            "--no-dev",
            "--no-emit-project",
            "--format",
            "requirements-txt",
        ],
        cwd=broker_root,
    )
    requirements.write_text(exported.stdout)

    _run(
        [
            "uv",
            "pip",
            "install",
            "--target",
            str(target),
            "-r",
            str(requirements),
            "--python-version",
            python_version,
            "--python-platform",
            platform,
            # A source distribution would be compiled for the BUILD machine, which is
            # the whole failure this flag exists to prevent. Fail loudly instead.
            "--only-binary=:all:",
        ],
        cwd=broker_root,
    )

    for entry in sorted(target.iterdir()):
        name = entry.name
        if name.endswith(_EXCLUDED_METADATA_SUFFIXES) or name.startswith(_EXCLUDED_DISTRIBUTIONS):
            shutil.rmtree(entry) if entry.is_dir() else entry.unlink()


def _shippable(root: Path) -> list[tuple[str, Path]]:
    """``(archive_name, source_path)`` pairs, sorted, with the exclusions applied."""
    found: list[tuple[str, Path]] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(root)
        if _EXCLUDED_DIR_NAMES.intersection(relative.parts):
            continue
        if relative.name in _EXCLUDED_NAMES:
            continue
        if path.suffix in _EXCLUDED_SUFFIXES:
            continue
        if relative.parts[0] == "app" and relative.name in _EXCLUDED_APP_FILES:
            continue
        found.append((relative.as_posix(), path))
    return sorted(found)


def write_zip(staged: Path, out_path: Path) -> str:
    """Write the package from a staged tree and return its sha256."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, source in _shippable(staged):
            info = zipfile.ZipInfo(name, date_time=_FIXED_DATE)
            # 0o644 in the high 16 bits, where zip keeps unix permissions. Left to
            # default, the mode follows the build machine's umask and the bytes stop
            # being reproducible.
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, source.read_bytes())
    return hashlib.sha256(out_path.read_bytes()).hexdigest()


def build(broker_root: Path, out_path: Path, *, platform: str, python_version: str) -> str:
    """Vendor the wheels, stage ``app/``, write the zip, return its sha256."""
    with tempfile.TemporaryDirectory() as tmp:
        staged = Path(tmp) / "pkg"
        staged.mkdir(parents=True)

        vendor(broker_root, staged, platform=platform, python_version=python_version)

        app_source = broker_root / "app"
        if not app_source.is_dir():
            raise FileNotFoundError(f"no app/ package under {broker_root}")
        shutil.copytree(app_source, staged / "app", dirs_exist_ok=True)

        return write_zip(staged, out_path)


def changed_since(broker_root: Path, ref: str) -> bool:
    """Would a build from ``ref`` differ? True iff a shipped input changed.

    THE PUBLISH GATE. Chargate releases are overwhelmingly CLI changes that touch
    nothing in this package; without this the infra leaf collects a stream of
    version-bump pull requests redeploying byte-identical code until nobody reads them.
    Conservative by construction — an unreadable ref answers True.
    """
    try:
        diff = _run(
            ["git", "diff", "--name-only", f"{ref}..HEAD"],
            cwd=broker_root.parent,
        )
    except subprocess.CalledProcessError:
        return True

    # `broker/pyproject.toml` IS watched, and it is not redundant with uv.lock. The build
    # ships whatever `uv export --frozen --no-dev` resolves, and that reads pyproject to decide
    # which dependencies and groups are in scope — so moving a package between `dependencies`
    # and an optional extra changes what lands in the zip while uv.lock stays byte-identical.
    # Without this, that change would never be published and the deployed broker would quietly
    # keep running the old dependency set.
    watched = (
        "broker/app/",
        "broker/uv.lock",
        "broker/pyproject.toml",
        "broker/scripts/build_lambda_zip.py",
    )
    for line in diff.stdout.splitlines():
        candidate = line.strip()
        if candidate.startswith(watched) and not candidate.endswith("/main.py"):
            return True
    return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--broker-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="the broker/ directory (holds pyproject.toml, uv.lock and app/)",
    )
    parser.add_argument("--out", type=Path, default=Path("dist/diatreme-broker.zip"))
    # NOT `required=True`, deliberately — see the check in the build path below. `--changed-since`
    # answers a question about git history and builds nothing, so demanding a platform for it made
    # the publish gate exit 2 on every release and took the whole release job with it.
    parser.add_argument(
        "--platform",
        help="uv --python-platform target, e.g. x86_64-manylinux_2_28. No default on purpose.",
    )
    parser.add_argument("--python-version", default="3.12")
    parser.add_argument(
        "--print-hash",
        action="store_true",
        help="print ONLY the sha256, for a CI comparison against the published object",
    )
    parser.add_argument(
        "--changed-since",
        metavar="REF",
        help="exit 0 and print 'true'/'false' for whether a shipped input changed since REF",
    )
    args = parser.parse_args(argv)

    if args.changed_since:
        print("true" if changed_since(args.broker_root, args.changed_since) else "false")
        return 0

    # Enforced HERE rather than by argparse, so it still fails loudly for a build but does not
    # apply to `--changed-since`. The guarantee that matters is unchanged: a build cannot pick a
    # platform for you, because `cryptography` ships compiled wheels and a Mac-resolved set
    # deploys cleanly and then ImportErrors at cold start.
    if not args.platform:
        parser.error("--platform is required when building (no default, on purpose)")

    digest = build(
        args.broker_root,
        args.out,
        platform=args.platform,
        python_version=args.python_version,
    )
    if args.print_hash:
        print(digest)
    else:
        print(f"{args.out}  {args.out.stat().st_size} bytes  sha256={digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
