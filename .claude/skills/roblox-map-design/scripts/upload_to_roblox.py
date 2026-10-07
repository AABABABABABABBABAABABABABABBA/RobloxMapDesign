#!/usr/bin/env python3
"""Upload Blender exports + baked textures to Roblox via Open Cloud, then generate the
Luau that inserts them into Studio automatically.

    export ROBLOX_API_KEY=...        # Open Cloud key with asset:read + asset:write
    export ROBLOX_CREATOR_ID=...     # your user id (or group id with --group)
    python3 upload_to_roblox.py --manifest export/manifest.json \
        [--textures textures/ --material Cliff_Stone=Slate:8 ...] \
        [--ledger map-memory/assets.json] [--dry-run]

What it does
  1. Uploads every model in the manifest as assetType "Model" (FBX) and every
     <Name>_{color,normal,roughness,metalness}.png in --textures as a "Decal".
  2. Polls the Open Cloud operation until it returns an assetId.
  3. Records everything in the ledger (map-memory/assets.json): name, family, sha1,
     assetId, date. Unchanged files (same sha1) are never uploaded twice.
  4. Writes map-memory/insert_assets.generated.luau = insert_assets.luau with the
     asset table filled in. Send that file's contents through Studio MCP `run_code`
     and the assets appear in ServerStorage.ScatterKit/<Family>/ and MaterialService.

Never print or commit the API key. Stdlib only (no requests).
"""
import argparse
import datetime as dt
import json
import mimetypes
import os
import re
import sys
import time
import urllib.error
import urllib.request
import uuid

API = "https://apis.roblox.com/assets/v1"
HERE = os.path.dirname(os.path.abspath(__file__))
MAP_KINDS = ("color", "normal", "roughness", "metalness")
CONTENT_TYPES = {".fbx": "model/fbx", ".glb": "model/gltf-binary", ".gltf": "model/gltf+json",
                 ".obj": "model/obj", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                 ".tga": "image/tga", ".bmp": "image/bmp"}


def sha1(path):
    import hashlib
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def request(method, url, key, body=None, headers=None):
    req = urllib.request.Request(url, data=body, method=method, headers={"x-api-key": key, **(headers or {})})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:500]
            if e.code in (429, 500, 502, 503) and attempt < 4:
                time.sleep(2 ** (attempt + 1))
                continue
            raise SystemExit(f"{method} {url} -> HTTP {e.code}: {detail}")
        except urllib.error.URLError:
            if attempt < 4:
                time.sleep(2 ** (attempt + 1))
                continue
            raise


def upload(path, asset_type, display, creator, key, description="Created with the roblox-map-design skill"):
    boundary = uuid.uuid4().hex
    meta = {
        "assetType": asset_type,
        "displayName": display[:50],
        "description": description[:1000],
        "creationContext": {"creator": creator},
    }
    ctype = CONTENT_TYPES.get(os.path.splitext(path)[1].lower()) or mimetypes.guess_type(path)[0] or "application/octet-stream"
    with open(path, "rb") as f:
        data = f.read()
    body = b"".join([
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json\r\n\r\n".encode(),
        json.dumps(meta).encode(), b"\r\n",
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"fileContent\"; filename=\"{os.path.basename(path)}\"\r\nContent-Type: {ctype}\r\n\r\n".encode(),
        data, b"\r\n", f"--{boundary}--\r\n".encode(),
    ])
    op = request("POST", f"{API}/assets", key, body, {"Content-Type": f"multipart/form-data; boundary={boundary}"})
    op_id = op.get("operationId") or (op.get("path", "").split("/")[-1])
    for _ in range(60):
        if op.get("done"):
            break
        time.sleep(2)
        op = request("GET", f"{API}/operations/{op_id}", key)
    if not op.get("done"):
        raise SystemExit(f"upload of {path} did not finish (operation {op_id})")
    resp = op.get("response") or {}
    asset_id = resp.get("assetId")
    if not asset_id:
        raise SystemExit(f"upload of {path} failed: {json.dumps(op)[:500]}")
    return str(asset_id), resp.get("moderationResult", {}).get("moderationState", "")


def luau_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def emit_luau(entries, out_path):
    with open(os.path.join(HERE, "insert_assets.luau")) as f:
        template = f.read()
    lines = ["local ASSETS = {"]
    for e in entries:
        if e["kind"] == "model":
            sx, sy, sz = e.get("size", [0, 0, 0])
            lines.append(
                f"\t{{ kind = \"model\", name = {luau_str(e['name'])}, family = {luau_str(e['family'])}, "
                f"assetId = {e['assetId']}, size = Vector3.new({sx}, {sy}, {sz}), sha1 = {luau_str(e['sha1'])} }},")
        else:
            maps = ", ".join(f"{k} = {v}" for k, v in sorted(e["maps"].items()))
            lines.append(
                f"\t{{ kind = \"material\", name = {luau_str(e['name'])}, base = {luau_str(e.get('base', 'Slate'))}, "
                f"studsPerTile = {e.get('studsPerTile', 8)}, maps = {{ {maps} }} }},")
    lines.append("}")
    generated = re.sub(r"local ASSETS = \{\}[^\n]*", "\n".join(lines).replace("\\", "\\\\"), template, count=1)
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w") as f:
        f.write(generated)
    return out_path


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", help="manifest.json from blender_export.py")
    ap.add_argument("--textures", help="folder of <Name>_<map>.png from blender_texture_bake.py")
    ap.add_argument("--material", action="append", default=[],
                    help="Name=BaseMaterial[:studsPerTile], e.g. Cliff_Stone=Slate:8 (default Slate:8)")
    ap.add_argument("--ledger", default="map-memory/assets.json")
    ap.add_argument("--out", default="map-memory/insert_assets.generated.luau")
    ap.add_argument("--group", action="store_true", help="ROBLOX_CREATOR_ID is a group id")
    ap.add_argument("--dry-run", action="store_true", help="no network; fake ids, still writes the Luau")
    a = ap.parse_args()

    key = os.environ.get("ROBLOX_API_KEY", "")
    creator_id = os.environ.get("ROBLOX_CREATOR_ID", "")
    if not a.dry_run and (not key or not creator_id):
        sys.exit("Set ROBLOX_API_KEY and ROBLOX_CREATOR_ID (see references/blender-pipeline.md). "
                 "Or import the FBX files by hand with Studio's 3D Importer.")
    creator = {"groupId": creator_id} if a.group else {"userId": creator_id}

    ledger = {}
    if os.path.exists(a.ledger):
        with open(a.ledger) as f:
            ledger = {e["name"] + "|" + e["kind"]: e for e in json.load(f)}

    fake = [10_000_000_000]

    def do_upload(path, asset_type, display):
        if a.dry_run:
            fake[0] += 1
            return str(fake[0]), "dry-run"
        return upload(path, asset_type, display, creator, key)

    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    touched = []

    if a.manifest:
        with open(a.manifest) as f:
            for m in json.load(f):
                k = m["name"] + "|model"
                prev = ledger.get(k)
                if prev and prev.get("sha1") == m["sha1"] and prev.get("assetId") and not prev.get("dryRun"):
                    print(f"= {m['name']}: unchanged, asset {prev['assetId']}")
                    touched.append(prev)
                    continue
                asset_id, mod = do_upload(m["file"], "Model", m["name"])
                e = {"kind": "model", "name": m["name"], "family": m["family"], "sha1": m["sha1"],
                     "assetId": asset_id, "size": m["size"], "tris": m.get("tris"), "uploaded": now,
                     "moderation": mod, "dryRun": a.dry_run}
                ledger[k] = e
                touched.append(e)
                print(f"+ {m['name']}: asset {asset_id} {mod}")

    if a.textures:
        mats = {}
        for spec in a.material:
            name, _, rest = spec.partition("=")
            base, _, spt = rest.partition(":")
            mats[name] = (base or "Slate", float(spt or 8))
        groups = {}
        for fn in sorted(os.listdir(a.textures)):
            mt = re.match(r"(.+)_(color|normal|roughness|metalness)\.(png|jpe?g|tga)$", fn, re.I)
            if mt:
                groups.setdefault(mt.group(1), {})[mt.group(2).lower()] = os.path.join(a.textures, fn)
        for name, files in groups.items():
            k = name + "|material"
            prev = ledger.get(k, {})
            maps = dict(prev.get("maps", {}))
            shas = dict(prev.get("shas", {}))
            for kind in MAP_KINDS:
                if kind not in files:
                    continue
                s = sha1(files[kind])
                if shas.get(kind) == s and kind in maps and not prev.get("dryRun"):
                    continue
                maps[kind], _ = do_upload(files[kind], "Decal", f"{name}_{kind}")
                shas[kind] = s
                print(f"+ {name}_{kind}: decal {maps[kind]}")
            base, spt = mats.get(name, (prev.get("base", "Slate"), prev.get("studsPerTile", 8)))
            e = {"kind": "material", "name": name, "maps": maps, "shas": shas, "base": base,
                 "studsPerTile": spt, "uploaded": now, "dryRun": a.dry_run}
            ledger[k] = e
            touched.append(e)

    os.makedirs(os.path.dirname(a.ledger) or ".", exist_ok=True)
    with open(a.ledger, "w") as f:
        json.dump(list(ledger.values()), f, indent=1)
    out = emit_luau(touched, a.out)
    print(f"ledger: {a.ledger}\nnext: send {out} through Studio MCP run_code")


if __name__ == "__main__":
    main()
