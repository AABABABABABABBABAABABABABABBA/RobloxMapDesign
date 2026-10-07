#!/usr/bin/env python3
"""Turn layout_snapshot.luau output into a top-down plan image (colour + hillshade).

Usage:
    python3 render_layout.py snapshot.txt -o renders/plan.png [--scale 10] [--grid 50]

The input is the text printed by layout_snapshot.luau (from "LAYOUT {...}" to
"END_LAYOUT"); other lines are ignored, so you can paste the whole run_code output.
Produces a PNG with: palette colour shaded by height (light from the north-west),
contour lines, a stud grid, a scale bar and north arrow. Requires Pillow.
"""
import argparse
import json
import math

from PIL import Image, ImageDraw


def parse(path):
    meta, rows, inside = None, [], False
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if line.startswith("LAYOUT "):
                meta = json.loads(line[7:])
                inside = True
                continue
            if line.startswith("END_LAYOUT"):
                break
            if inside and line:
                rows.append(line)
    if meta is None:
        raise SystemExit("no LAYOUT header found")
    n = meta["cells"]
    grid = []
    for line in rows[:n]:
        cells = []
        for i in range(n):
            tok = line[i * 5:(i + 1) * 5]
            if not tok or tok == ".....":
                cells.append(None)
            else:
                r, g, b = (int(tok[k], 16) * 17 for k in range(3))
                cells.append(((r, g, b), int(tok[3:5], 16) / 255))
        grid.append(cells)
    return meta, grid


def render(meta, grid, scale, grid_studs):
    n = meta["cells"]
    W = n * scale
    img = Image.new("RGB", (W, W + 40), (24, 24, 28))
    px = img.load()
    hspan = meta["hMax"] - meta["hMin"]
    cell = meta["cell"]

    def h(r, c):
        if 0 <= r < n and 0 <= c < n and grid[r][c]:
            return grid[r][c][1] * hspan
        return None

    for r in range(n):
        for c in range(n):
            v = grid[r][c]
            if not v:
                col = (40, 40, 48)
            else:
                (cr, cg, cb), _ = v
                h0 = h(r, c)
                hx = h(r, c - 1)
                hz = h(r - 1, c)
                dx = (h0 - hx) / cell if hx is not None else 0
                dz = (h0 - hz) / cell if hz is not None else 0
                # light from north-west, slope shading
                shade = max(0.45, min(1.35, 1 + (dx + dz) * 0.35))
                col = tuple(max(0, min(255, int(ch * shade))) for ch in (cr, cg, cb))
            for y in range(scale):
                for x in range(scale):
                    px[c * scale + x, r * scale + y] = col

    d = ImageDraw.Draw(img)
    # contours every ~10% of height range
    if hspan > 0.5:
        step = max(hspan / 10, 1)
        for r in range(n):
            for c in range(n):
                a, b = h(r, c), h(r, c + 1)
                if a is not None and b is not None and math.floor(a / step) != math.floor(b / step):
                    d.line([((c + 1) * scale, r * scale), ((c + 1) * scale, (r + 1) * scale)], fill=(0, 0, 0), width=1)
                b = h(r + 1, c)
                if a is not None and b is not None and math.floor(a / step) != math.floor(b / step):
                    d.line([(c * scale, (r + 1) * scale), ((c + 1) * scale, (r + 1) * scale)], fill=(0, 0, 0), width=1)
    # stud grid
    if grid_studs > 0:
        x0, z0 = meta["minX"], meta["minZ"]
        k = math.ceil(x0 / grid_studs) * grid_studs
        while k < x0 + n * cell:
            X = (k - x0) / cell * scale
            d.line([(X, 0), (X, W)], fill=(255, 255, 255), width=1)
            d.text((X + 2, 2), f"x{int(k)}", fill=(255, 255, 255))
            k += grid_studs
        k = math.ceil(z0 / grid_studs) * grid_studs
        while k < z0 + n * cell:
            Z = (k - z0) / cell * scale
            d.line([(0, Z), (W, Z)], fill=(255, 255, 255), width=1)
            d.text((2, Z + 2), f"z{int(k)}", fill=(255, 255, 255))
            k += grid_studs
    # scale bar + legend
    bar_studs = grid_studs or 50
    bar_px = bar_studs / cell * scale
    d.rectangle([10, W + 14, 10 + bar_px, W + 20], fill=(240, 240, 240))
    d.text((14 + bar_px, W + 10), f"{bar_studs} studs   cell={cell:.1f} studs   height {meta['hMin']:.0f}..{meta['hMax']:.0f}   top = -Z", fill=(220, 220, 220))
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("snapshot")
    ap.add_argument("-o", "--out", default="plan.png")
    ap.add_argument("--scale", type=int, default=10, help="pixels per cell")
    ap.add_argument("--grid", type=float, default=50, help="grid spacing in studs (0 = off)")
    a = ap.parse_args()
    meta, grid = parse(a.snapshot)
    render(meta, grid, a.scale, a.grid).save(a.out)
    print("wrote", a.out)


if __name__ == "__main__":
    main()
