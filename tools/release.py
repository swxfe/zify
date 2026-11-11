#!/usr/bin/env python3
"""Describe the exact code/resource pair published from one Git revision."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tarfile


def metadata(code, assets):
    body = Path(code).read_bytes()
    version = re.search(rb"^# ZIFY_VERSION=([0-9]+\.[0-9]+(?:\.[0-9]+)?)$", body, re.M)
    if version is None or b"\n# ZIFY_FORMAT=2\n" not in body:
        raise ValueError("incompatible zify executable")
    version = version[1].decode()
    with tarfile.open(assets) as archive:
        manifest = json.load(archive.extractfile("manifest.json"))
    if manifest["version"] != version:
        raise ValueError("code and resource versions differ")
    result = {"format": 1, "bundle_format": 2, "version": version}
    for kind, local, remote, limit in [("code", code, "dist/zify.sh", 2097152),
                                       ("assets", assets, "dist/zify-assets.tar.gz", 8388608)]:
        payload = Path(local).read_bytes()
        if not 0 < len(payload) <= limit:
            raise ValueError("invalid release size: " + kind)
        result[kind] = {"path": remote, "size": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
    return result


def write(path, body):
    path = Path(path)
    staged = path.with_name(path.name + ".tmp")
    staged.write_bytes(body)
    staged.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--code", default="dist/zify.sh")
    parser.add_argument("--assets", default="dist/zify-assets.tar.gz")
    parser.add_argument("--output-dir", default="dist")
    args = parser.parse_args()
    output = Path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    data = metadata(args.code, args.assets)
    write(output / "release.json", (json.dumps(data, indent=2) + "\n").encode())
    checksums = []
    for name, path in [("zify.sh", Path(args.code)), ("zify-assets.tar.gz", Path(args.assets)),
                       ("release.json", output / "release.json")]:
        checksums.append(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + name)
    write(output / "SHA256SUMS", ("\n".join(checksums) + "\n").encode())
    print("Release " + data["version"] + ": code, resources and checksums ready")


if __name__ == "__main__":
    main()
