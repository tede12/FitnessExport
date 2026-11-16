#!/usr/bin/env python3
"""Check source for private data and unsafe fixture addresses."""

import argparse
import ipaddress
import re
import subprocess
from pathlib import Path

DOCUMENTATION_NETWORKS = tuple(ipaddress.ip_network(value) for value in (
    "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "127.0.0.0/8",
))
PRIVATE_FILENAMES = {".env", "personal-context.json", "athlete-profile.md",
                     "heart-rate-zones.json", "body-assessments.json", "labs.json"}
PRIVATE_SUFFIXES = {".sqlite", ".db", ".fit", ".gpx", ".tcx", ".p12", ".p8"}


def review(root, forbidden):
    names = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root,
    ).decode().split("\0")
    findings = []
    scanned = 0
    for name in sorted(set(names)):
        if not name:
            continue
        path = root / name
        if not path.is_file():
            continue
        scanned += 1
        if path.name in PRIVATE_FILENAMES or path.suffix.lower() in PRIVATE_SUFFIXES:
            findings.append(f"{name}: private file type must not be shared")
        raw = path.read_bytes()
        for value in forbidden:
            if value.encode().lower() in raw.lower():
                findings.append(f"{name}: explicitly forbidden identifier")
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if re.search(r"/(?:Users|home)/[A-Za-z0-9_.-]+/", text):
            findings.append(f"{name}: absolute home directory")
        if re.search(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", text):
            findings.append(f"{name}: private key material")
        for candidate in set(re.findall(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])", text)):
            try:
                address = ipaddress.ip_address(candidate)
            except ValueError:
                continue
            if not any(address in network for network in DOCUMENTATION_NETWORKS):
                findings.append(f"{name}: fixed IP outside documentation/loopback ranges")
        for address in re.findall(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", text):
            if not address.endswith(("@example.com", "@example.org", ".invalid", "@users.noreply.github.com")):
                findings.append(f"{name}: email address requires review")
    return scanned, sorted(set(findings))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--forbid-text", action="append", default=[], help="Additional identifier to reject (case insensitive)")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    scanned, findings = review(root, args.forbid_text)
    for finding in findings:
        print(finding)
    print(f"Reviewed {scanned} source files; {len(findings)} findings.")
    return bool(findings)


if __name__ == "__main__":
    raise SystemExit(main())
