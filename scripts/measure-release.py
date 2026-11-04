# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 AQuantum Reader contributors.
"""Read-only archive/directory size census; preserve raw bytes and file hashes."""
import argparse
import hashlib
import json
import os
import pathlib
import stat
import zipfile


def is_link(path):
    metadata = path.lstat()
    return stat.S_ISLNK(metadata.st_mode) or bool(getattr(metadata, "st_file_attributes", 0) & 0x400)


def measure(path):
    path = pathlib.Path(path).resolve(strict=True)
    if path.is_dir():
        files = []
        for parent, dirs, names in os.walk(path, followlinks=False):
            parent = pathlib.Path(parent)
            # Never follow junctions or symlinks into other trees.
            dirs[:] = [d for d in dirs if not is_link(parent / d)]
            for name in names:
                file = parent / name
                if is_link(file):
                    continue
                with file.open("rb") as stream:
                    digest = hashlib.file_digest(stream, "sha256").hexdigest()
                files.append({"name": file.relative_to(path).as_posix(),
                              "bytes": file.stat().st_size,
                              "sha256": digest})
        return {"path": str(path), "kind": "directory", "fileCount": len(files),
                "expandedBytes": sum(f["bytes"] for f in files), "files": files}
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    result = {"path": str(path), "downloadBytes": path.stat().st_size, "sha256": digest}
    if not zipfile.is_zipfile(path):
        return result
    with zipfile.ZipFile(path) as archive:
        bad = archive.testzip()
        if bad:
            raise ValueError(f"CRC failed: {bad}")
        files = [{"name": f.filename, "bytes": f.file_size,
                  "compressedBytes": f.compress_size, "crc32": f.CRC}
                 for f in archive.infolist() if not f.is_dir()]
    result.update(kind="archive", crc="passed", fileCount=len(files),
                  expandedBytes=sum(f["bytes"] for f in files),
                  nativeBytes=sum(f["bytes"] for f in files
                                  if f["name"].endswith((".so", ".dll", ".exe"))),
                  flutterAssetBytes=sum(f["bytes"] for f in files
                                        if "flutter_assets/" in f["name"]),
                  files=sorted(files, key=lambda f: f["bytes"], reverse=True))
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    result = {"schema": 1, "units": "bytes; archive expansion is not installed disk allocation",
              "artifacts": [measure(p) for p in args.paths]}
    with open(args.output, "x", encoding="utf-8") as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)
    for item in result["artifacts"]:
        print(pathlib.Path(item["path"]).name, item.get("downloadBytes"), item.get("expandedBytes"))
