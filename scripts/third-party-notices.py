#!/usr/bin/env python3
"""Prints the app's ThirdPartyNotices.txt: App/Resources/ThirdPartyNotices.txt (rhwp, SwiftMath)
followed by the license of every Rust crate linked into the engine (from `cargo metadata`)."""
import glob, json, os, subprocess, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
# Ours, and rhwp's crates (rhwp's license is in the hand-written part).
SKIP = ("hwp-engine-abi", "rhwp")
# Licenses that ask for no notice in a binary; a crate offering one may ship no file.
NO_NOTICE = ("Zlib", "Unlicense", "0BSD", "CC0-1.0", "MIT-0")

meta = json.loads(subprocess.check_output(
    ["cargo", "metadata", "--format-version", "1", "--locked",
     "--manifest-path", os.path.join(ROOT, "Engine", "Cargo.toml"),
     "--filter-platform", "aarch64-apple-darwin"]))
packages = {p["id"]: p for p in meta["packages"]}
nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}

linked, stack = set(), list(meta["workspace_members"])
while stack:
    i = stack.pop()
    if i not in linked:
        linked.add(i)
        stack += [d["pkg"] for d in nodes[i]["deps"]
                  if any(k["kind"] is None for k in d["dep_kinds"])]


def license_texts(p):
    """MIT's text for a crate that offers it, else every license file it ships."""
    folder = os.path.dirname(p["manifest_path"])
    files = sorted(f for f in glob.glob(os.path.join(folder, "*"))
                   if os.path.basename(f).upper().startswith(("LICENSE", "LICENCE", "COPYING", "UNLICENSE", "NOTICE")))
    if p.get("license_file"):
        files = [os.path.join(folder, p["license_file"])]
    mit = [f for f in files if "MIT" in os.path.basename(f).upper()]
    if mit and "MIT" in (p["license"] or ""):
        files = mit
    return [open(f, encoding="utf-8", errors="replace").read().strip() for f in files]


out = [open(os.path.join(ROOT, "App", "Resources", "ThirdPartyNotices.txt"), encoding="utf-8").read().rstrip()]
missing = []
for p in sorted((packages[i] for i in linked), key=lambda p: p["name"]):
    if p["name"].startswith(SKIP):
        continue
    texts = license_texts(p)
    if not texts and not any(l in (p["license"] or "") for l in NO_NOTICE):
        missing.append(p["name"])
    head = f'{p["name"]} {p["version"]} — {p["license"]}'
    if p.get("repository"):
        head += f' — {p["repository"]}'
    if p["authors"]:
        head += "\n" + ", ".join(p["authors"])
    out.append("\n\n".join([head] + texts))
print("\n\n\n".join(out))
if missing:
    sys.exit("no license file: " + ", ".join(missing))
