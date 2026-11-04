# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 AQuantum Reader contributors.
"""Synthetic C ABI benchmark. Creates a new isolated library, never user data."""
import argparse
import ctypes
import hashlib
import json
import pathlib
import platform
import statistics
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True)
    parser.add_argument("--output", required=True, help="New run directory")
    parser.add_argument("--books", type=int, default=200)
    parser.add_argument("--rounds", type=int, default=21)
    args = parser.parse_args()
    if args.books < 1 or args.rounds < 3:
        parser.error("Use at least one book and three rounds")
    root = pathlib.Path(args.output).resolve()
    root.mkdir(parents=True, exist_ok=False)
    library_path = pathlib.Path(args.library).resolve(strict=True)
    dll = ctypes.CDLL(str(library_path))
    dll.aq_invoke_json.argtypes = [ctypes.c_char_p]
    dll.aq_invoke_json.restype = ctypes.c_void_p
    dll.aq_free_json.argtypes = [ctypes.c_void_p]
    dll.aq_free_json.restype = None

    def call(method, **values):
        request = json.dumps({"root": str(root / "data"), "method": method,
                              "args": values}).encode()
        ptr = dll.aq_invoke_json(request)
        try:
            value = json.loads(ctypes.string_at(ptr))
        finally:
            dll.aq_free_json(ptr)
        if not value["ok"]:
            raise RuntimeError(value)
        return value["data"]

    def timed(operation):
        values = []
        for _ in range(args.rounds):
            start = time.perf_counter_ns()
            operation()
            values.append((time.perf_counter_ns() - start) / 1e6)
        return {"medianMs": statistics.median(values),
                "p95Ms": sorted(values)[int((len(values) - 1) * .95 + .999)],
                "samplesMs": values}

    start = time.perf_counter_ns()
    inbox = call("snapshot")["catalog"]["inbox"]
    first_snapshot_ms = (time.perf_counter_ns() - start) / 1e6
    fixtures = root / "fixtures"
    fixtures.mkdir()
    source = "第一章 基准\n\n" + "Synthetic searchable reader content. 中文内容。\n\n" * 80
    paths = []
    for index in range(args.books):
        path = fixtures / f"book-{index:04}.txt"
        path.write_text(source, encoding="utf-8")
        paths.append(str(path))
    plan = call("preview_import", target=inbox, paths=paths)
    imported = call("commit_import", task=plan["task"], base_revision=plan["base_revision"],
                    target=plan["target"], projects=[],
                    books=[{"id": b["id"], "title": b["title"], "project": b["project"],
                            "resources": [r["id"] for r in b["resources"]]} for b in plan["books"]],
                    skip_issues=False, append=None)
    assert len(imported["books"]) == args.books
    assert call("build_index")["indexed"] == args.books
    book = imported["books"][0]
    # 100 is the public hit limit, not a reduced test workload.
    assert len(call("search_text", query="searchable")) == min(100, args.books * 80)
    result = {"platform": platform.platform(), "mode": "native Release DLL via C ABI",
              "scope": "synthetic; OS cache retained; not Flutter startup, UI latency or device RSS",
              "books": args.books, "rounds": args.rounds, "sourceSha256": hashlib.sha256(source.encode()).hexdigest(),
              "librarySha256": hashlib.file_digest(library_path.open("rb"), "sha256").hexdigest(),
              "firstEmptySnapshotMs": first_snapshot_ms,
              "snapshot": timed(lambda: call("snapshot")),
              "indexStatus": timed(lambda: call("index_status")),
              "searchText": timed(lambda: call("search_text", query="searchable")),
              "readText": timed(lambda: call("read_text", book=book))}
    with (root / "measurements.json").open("x", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps({k: v for k, v in result.items() if k not in ("sourceSha256", "librarySha256")}, indent=2))


if __name__ == "__main__":
    main()
