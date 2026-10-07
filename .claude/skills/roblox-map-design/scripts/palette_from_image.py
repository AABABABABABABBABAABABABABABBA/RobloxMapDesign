#!/usr/bin/env python3
"""Extract a role-labelled colour palette from reference images.

Usage:
    python3 palette_from_image.py reference-images/*.png --colors 7 [--json out.json]

Prints hex, Color3.fromRGB(...), coverage and a suggested role for each colour,
followed by a Luau PALETTE table ready to paste into build scripts.
Requires Pillow (pip install pillow). Pure-Python k-means, no numpy needed.
"""
import argparse
import colorsys
import json
import random
import sys

from PIL import Image


def load_pixels(paths, side=72):
    px = []
    for p in paths:
        im = Image.open(p).convert("RGB")
        im.thumbnail((side, side))
        px.extend(im.get_flattened_data() if hasattr(im, "get_flattened_data") else im.getdata())
    return px


def kmeans(points, k, iters=20, seed=1):
    rnd = random.Random(seed)
    # k-means++ init
    centers = [rnd.choice(points)]
    while len(centers) < k:
        d2 = [min(sum((a - b) ** 2 for a, b in zip(p, c)) for c in centers) for p in points]
        total = sum(d2) or 1
        r, acc = rnd.random() * total, 0
        for p, d in zip(points, d2):
            acc += d
            if acc >= r:
                centers.append(p)
                break
    for _ in range(iters):
        buckets = [[] for _ in centers]
        for p in points:
            i = min(range(len(centers)), key=lambda c: sum((a - b) ** 2 for a, b in zip(p, centers[c])))
            buckets[i].append(p)
        new = []
        for b, c in zip(buckets, centers):
            if b:
                new.append(tuple(sum(ch) / len(b) for ch in zip(*b)))
            else:
                new.append(c)
        if all(sum(abs(a - b) for a, b in zip(n, c)) < 0.5 for n, c in zip(new, centers)):
            centers = new
            break
        centers = new
    counts = [0] * len(centers)
    for p in points:
        i = min(range(len(centers)), key=lambda c: sum((a - b) ** 2 for a, b in zip(p, centers[c])))
        counts[i] += 1
    return [(tuple(int(round(v)) for v in c), n / len(points)) for c, n in zip(centers, counts)]


def luminance(rgb):
    r, g, b = (v / 255 for v in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def saturation(rgb):
    return colorsys.rgb_to_hsv(*(v / 255 for v in rgb))[1]


def assign_roles(palette):
    roles = {}
    remaining = list(range(len(palette)))
    by_cov = sorted(remaining, key=lambda i: -palette[i][1])
    roles[by_cov[0]] = "dominant"
    remaining.remove(by_cov[0])
    if remaining:
        shadow = min(remaining, key=lambda i: luminance(palette[i][0]))
        roles[shadow] = "shadow"
        remaining.remove(shadow)
    if remaining:
        hi = max(remaining, key=lambda i: luminance(palette[i][0]))
        roles[hi] = "highlight"
        remaining.remove(hi)
    if remaining:
        accent = max(remaining, key=lambda i: saturation(palette[i][0]) * (1.2 - palette[i][1]))
        roles[accent] = "accent"
        remaining.remove(accent)
    for n, i in enumerate(sorted(remaining, key=lambda i: -palette[i][1])):
        roles[i] = "secondary" if n == 0 else f"support{n}"
    return roles


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("images", nargs="+")
    ap.add_argument("--colors", type=int, default=7)
    ap.add_argument("--json", help="also write the palette to this JSON file")
    a = ap.parse_args()

    px = load_pixels(a.images)
    if not px:
        sys.exit("no pixels loaded")
    pal = sorted(kmeans(px, a.colors), key=lambda c: -c[1])
    roles = assign_roles(pal)

    print(f"Palette from {len(a.images)} image(s), {len(px)} samples\n")
    print(f"{'role':<11} {'hex':<8} {'coverage':>8}  Color3")
    out = []
    for i, (rgb, cov) in enumerate(pal):
        hexv = "#%02x%02x%02x" % rgb
        print(f"{roles[i]:<11} {hexv:<8} {cov*100:7.1f}%  Color3.fromRGB({rgb[0]}, {rgb[1]}, {rgb[2]})")
        out.append({"role": roles[i], "hex": hexv, "rgb": rgb, "coverage": round(cov, 4)})

    print("\n-- Luau")
    print("local PALETTE = {")
    for o in out:
        r, g, b = o["rgb"]
        print(f'\t{o["role"]} = Color3.fromRGB({r}, {g}, {b}), -- {o["hex"]} {o["coverage"]*100:.0f}%')
    print("}")
    print("\nNotes: use dominant/secondary desaturated on large surfaces, accent only on"
          " things players should notice; avoid pure black/white.")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(out, f, indent=2)


if __name__ == "__main__":
    main()
