#!/usr/bin/env python3
"""Fetch the commit-pinned public corpus without changing its original bytes."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path, help="New, isolated corpus directory")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    if manifest["schemaVersion"] != 1 or not manifest["documents"]:
        raise ValueError("Unsupported or empty corpus")
    args.output.mkdir(parents=True, exist_ok=False)
    documents = args.output / "documents"
    documents.mkdir()
    for index, document in enumerate(manifest["documents"]):
        expected_size = document["byteCount"]
        with urllib.request.urlopen(document["rawURL"], timeout=30) as response:
            data = response.read(expected_size + 1)
        if len(data) != expected_size or hashlib.sha256(data).hexdigest() != document["sha256"]:
            raise ValueError(f"Original bytes/hash mismatch: {document['id']}")
        # Use a local ordinal, never a path from a downloaded document.
        filename = f"document-{index:02d}.md"
        (documents / filename).write_bytes(data)
        document["localFile"] = "documents/" + filename
        print(f"VERIFIED {document['id']} {len(data)} bytes {document['sha256']}")
    path = args.output / "manifest.json"
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(path.resolve())


if __name__ == "__main__":
    main()
