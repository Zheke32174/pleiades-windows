#!/usr/bin/env python3
"""Build a deterministic Windows source ZIP, SPDX inventory, and release receipt."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import re
import subprocess
import zipfile

VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
RECEIPT_SCHEMA = "pleiades.windows.source-release/v1"


def git(root: pathlib.Path, *args: str, binary: bool = False) -> str | bytes:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        check=False,
        capture_output=True,
        text=not binary,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace") if binary else result.stderr
        raise SystemExit(f"git {' '.join(args)} failed: {detail.strip()}")
    return result.stdout


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_manifest(root: pathlib.Path, commit: str) -> list[str]:
    manifest = root / "release" / "source-files.txt"
    lines = manifest.read_text(encoding="utf-8").splitlines()
    paths = [line.strip() for line in lines if line.strip() and not line.lstrip().startswith("#")]
    if not paths:
        raise SystemExit("release/source-files.txt must not be empty")
    if paths != sorted(paths) or len(paths) != len(set(paths)):
        raise SystemExit("release/source-files.txt must be sorted and unique")
    for path in paths:
        pure = pathlib.PurePosixPath(path)
        if path.startswith("/") or ".." in pure.parts or path.endswith("/"):
            raise SystemExit(f"unsafe release path: {path}")
        check = subprocess.run(
            ["git", "cat-file", "-e", f"{commit}:{path}"],
            cwd=root,
            check=False,
            capture_output=True,
        )
        if check.returncode != 0:
            raise SystemExit(f"release path missing from reviewed commit: {path}")
    return paths


def git_mode(root: pathlib.Path, commit: str, path: str) -> int:
    output = str(git(root, "ls-tree", commit, "--", path)).strip()
    if not output:
        raise SystemExit(f"unable to read Git mode for {path}")
    mode = output.split(maxsplit=1)[0]
    return 0o100755 if mode == "100755" else 0o100644


def spdx_id(path: str) -> str:
    return f"SPDXRef-File-{hashlib.sha256(path.encode('utf-8')).hexdigest()[:24]}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("dist"))
    args = parser.parse_args()

    root = pathlib.Path(__file__).resolve().parents[1]
    version = (root / "VERSION").read_text(encoding="utf-8").strip()
    if not VERSION_RE.fullmatch(version):
        raise SystemExit(f"invalid VERSION: {version}")

    dirty = str(git(root, "status", "--porcelain", "--untracked-files=no"))
    if dirty:
        raise SystemExit("tracked working tree is dirty; package only an exact reviewed commit")

    commit = str(git(root, "rev-parse", "HEAD")).strip()
    epoch = int(str(git(root, "show", "-s", "--format=%ct", commit)).strip())
    timestamp = dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc)
    zip_time = (timestamp.year, timestamp.month, timestamp.day, timestamp.hour, timestamp.minute, timestamp.second)
    created = timestamp.strftime("%Y-%m-%dT%H:%M:%SZ")
    paths = read_manifest(root, commit)
    prefix = f"pleiades-windows-{version}"

    output = args.output if args.output.is_absolute() else root / args.output
    output.mkdir(parents=True, exist_ok=True)
    for child in output.iterdir():
        if child.is_file():
            child.unlink()

    archive_path = output / f"{prefix}.zip"
    file_records: list[dict[str, object]] = []
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in paths:
            data = bytes(git(root, "show", f"{commit}:{path}", binary=True))
            info = zipfile.ZipInfo(f"{prefix}/{path}", date_time=zip_time)
            info.create_system = 3
            info.external_attr = git_mode(root, commit, path) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            info.flag_bits = 0x800
            archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
            file_records.append(
                {
                    "path": path,
                    "sha256": sha256(data),
                    "size": len(data),
                    "spdx_id": spdx_id(path),
                }
            )

    spdx_path = output / f"{prefix}.spdx.json"
    relationships = [
        {
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": "SPDXRef-Package",
        }
    ]
    spdx_files = []
    for record in file_records:
        spdx_files.append(
            {
                "fileName": f"./{record['path']}",
                "SPDXID": record["spdx_id"],
                "checksums": [{"algorithm": "SHA256", "checksumValue": record["sha256"]}],
                "licenseConcluded": "NOASSERTION",
                "copyrightText": "NOASSERTION",
            }
        )
        relationships.append(
            {
                "spdxElementId": "SPDXRef-Package",
                "relationshipType": "CONTAINS",
                "relatedSpdxElement": record["spdx_id"],
            }
        )

    spdx = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": prefix,
        "documentNamespace": f"https://github.com/Zheke32174/pleiades-windows/sbom/{commit}",
        "creationInfo": {"created": created, "creators": ["Tool: scripts/package_release.py"]},
        "packages": [
            {
                "name": "pleiades-windows",
                "SPDXID": "SPDXRef-Package",
                "versionInfo": version,
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": True,
                "licenseConcluded": "MIT",
                "licenseDeclared": "MIT",
                "copyrightText": "Copyright (c) 2026 Pleiades Contributors",
                "externalRefs": [
                    {
                        "referenceCategory": "PACKAGE-MANAGER",
                        "referenceType": "purl",
                        "referenceLocator": f"pkg:github/Zheke32174/pleiades-windows@{commit}",
                    }
                ],
            }
        ],
        "files": spdx_files,
        "relationships": relationships,
    }
    spdx_path.write_text(json.dumps(spdx, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    archive_hash = sha256(archive_path.read_bytes())
    spdx_hash = sha256(spdx_path.read_bytes())
    manifest_hash = sha256((root / "release" / "source-files.txt").read_bytes())
    receipt_path = output / f"{prefix}.build-receipt.json"
    receipt = {
        "schema": RECEIPT_SCHEMA,
        "repository": "Zheke32174/pleiades-windows",
        "version": version,
        "commit": commit,
        "source_date_epoch": epoch,
        "created_from_commit_time": created,
        "release_manifest": {
            "name": "release/source-files.txt",
            "sha256": manifest_hash,
            "file_count": len(paths),
        },
        "archive": {"name": archive_path.name, "sha256": archive_hash},
        "sbom": {"name": spdx_path.name, "sha256": spdx_hash, "format": "SPDX-2.3 JSON"},
        "distribution": "unsigned-source",
        "scripts_authenticode_signed": False,
        "contains_runtime_state": False,
        "contains_event_records": False,
        "contains_credentials": False,
        "contains_wsl_distribution": False,
        "contains_web_server": False,
        "tasks_registered_by_package_build": False,
        "authority": "Windows host observation and one bounded WSL unit-start request",
    }
    receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    sums = []
    for path in sorted((archive_path, receipt_path, spdx_path), key=lambda item: item.name):
        sums.append(f"{sha256(path.read_bytes())}  {path.name}")
    (output / "SHA256SUMS.txt").write_text("\n".join(sums) + "\n", encoding="utf-8")

    print(f"PACKAGE {archive_path}")
    print(f"SBOM {spdx_path}")
    print(f"RECEIPT {receipt_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
