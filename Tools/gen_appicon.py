# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow", "resvg-py", "fonttools"]
# ///
"""Generate the Runlet app icon (all 10 AppIcon sizes).

Pipeline: the icon is drawn as SVG — vector ellipses, gradient fills and the
R mark embedded as a glyph outline path (fontTools) — rendered to a 2048
master with resvg, then downscaled with Pillow. Everything stays in memory;
only the 10 PNGs (and `--preview`, if given) touch disk.

Design: 3-layer disc stack measured from the Sequel Ace icon (disc radius,
ellipse ratio, stack height and position); stack colors sampled from the
original icon in commit b6c40c61 (vivid red/yellow/blue); light background
from the previous generation. The R mark is painted onto the top face: the
glyph is first rotated inside the disc plane (like a bucket spinning in
place), then foreshortened vertically by the face's ry/rx ratio, so it reads
as lying on the disc. Each side wall carries the arc-following ramp of the
numpy-drawn predecessor: a center-anchored and an edge-anchored vertical
ramp blended by a mask of 1-sqrt(1-(dx/rx)^2) reproduces it exactly, since
the ramp's iso-lines are the front arc translated downward.

Usage:
    uv run Tools/gen_appicon.py [--gap 34] [--spin 25] [--ratio 0.333]
                                [--font-size 340]
                                [--preview /tmp/runlet_icon_master.png]

Writes the 10 PNGs into Assets.xcassets/Runlet.appiconset/ by default.
"""
import argparse
import io
import math
import sys
from pathlib import Path

import resvg_py
from PIL import Image
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.ttLib import TTCollection, TTFont

ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "Assets.xcassets" / "Runlet.appiconset"

# ---- geometry (1024-space), measured from Sequel Ace's AppIcon ----
OUT = 1024
RENDER_PX = 2048            # resvg master size before downscaling
TILE_R = 170                # baked rounded corner (legacy-format icons render as-is)
CX = 512
RX, RY = 282, 94            # disc ellipse (ry/rx = 0.333)
STACK_H = 567               # stack height fixed at the measured value (93+188+47+95+49+95);
                            # the three side walls share what the gaps leave, so the
                            # silhouette keeps its original size at any gap
GAP = 34                    # slot between the layers (numpy build used 47 / 49)
STACK_SCALE = 1.28          # grow the stack to fill the full-bleed canvas (b6 fill factor)
FACE_DY = 2                 # R mark center sits this far below the top-face center

# ---- R mark (same values as the numpy-drawn predecessor) ----
SPIN = 25.0                 # in-plane rotation, deg CCW
RATIO = RY / RX             # face foreshortening
FONT_SIZE = 340.0           # em size in 1024-space

# ---- palette: sampled from the icon in commit b6c40c61 ----
BG_TOP, BG_BOT = "#F7F8FA", "#EDEFF3"
RED = dict(face_light="#F8615F", face_deep="#E14036",
           wall_light="#EE534E", wall_mid="#E94B44", wall_deep="#E03E37")
YELLOW = dict(face_light="#F6AD26", face_deep="#F5A824",
              wall_light="#F6AD26", wall_mid="#F8B82C", wall_deep="#F5A824")
BLUE = dict(face_light="#55A3B9", face_deep="#4B92D6",
            wall_light="#55A3B9", wall_mid="#509BC7", wall_deep="#4B92D6")
AO_RGB = (30, 24, 34)       # contact shadow between layers
GROUND_RGB = (52, 58, 76)   # ground shadow under the stack

SIZES = {"icon_512x512@2x.png": 1024, "icon_512x512.png": 512,
         "icon_256x256@2x.png": 512, "icon_256x256.png": 256,
         "icon_128x128@2x.png": 256, "icon_128x128.png": 128,
         "icon_32x32@2x.png": 64, "icon_32x32.png": 32,
         "icon_16x16@2x.png": 32, "icon_16x16.png": 16}

GAUSS_F = (0, 1 / 6, 1 / 3, 1 / 2, 2 / 3, 5 / 6, 1)  # radial stops sampling exp(-x^2/2)


def n(v: float) -> str:
    s = f"{v:.2f}"
    return s.rstrip("0").rstrip(".") if "." in s else s


# ---- SVG primitives ----

def linear(pid, x1, y1, x2, y2, stops):
    return (f'<linearGradient id="{pid}" gradientUnits="userSpaceOnUse" '
            f'x1="{n(x1)}" y1="{n(y1)}" x2="{n(x2)}" y2="{n(y2)}">{stops}</linearGradient>')


def stop(offset, color, opacity=1.0):
    extra = "" if opacity >= 1 else f' stop-opacity="{opacity:.4f}"'
    return f'<stop offset="{n(offset)}" stop-color="{color}"{extra}/>'


def radial_gaussian(pid, cx, cy, sx, sy, peak, rgb):
    """Elliptical Gaussian blob: unit circle warped by translate+scale, stops
    sampling exp(-4.5 f^2) over a 3-sigma radius."""
    stops = "".join(
        stop(f, f"rgb{rgb}", 0 if f == 1 else peak * math.exp(-4.5 * f * f))
        for f in GAUSS_F)
    return (f'<radialGradient id="{pid}" gradientUnits="userSpaceOnUse" cx="0" cy="0" r="1" '
            f'gradientTransform="translate({n(cx)} {n(cy)}) scale({n(3 * sx)} {n(3 * sy)})">'
            f'{stops}</radialGradient>')


def blob(pid, cx, cy, sx, sy, peak, rgb):
    """A Gaussian blob element plus its gradient def."""
    grad = radial_gaussian(pid, cx, cy, sx, sy, peak, rgb)
    el = (f'<ellipse cx="{n(cx)}" cy="{n(cy)}" rx="{n(3 * sx)}" ry="{n(3 * sy)}" '
          f'fill="url(#{pid})"/>')
    return grad, el


def band_path(cy, wall):
    """Wall only: front arc down `wall`, back along the translated arc."""
    return (f"M{n(CX - RX)} {n(cy)} A{n(RX)} {n(RY)} 0 0 0 {n(CX + RX)} {n(cy)} "
            f"L{n(CX + RX)} {n(cy + wall)} A{n(RX)} {n(RY)} 0 0 1 {n(CX - RX)} {n(cy + wall)} Z")


def cylinder_path(cy, wall):
    """Full silhouette: back arc, sides, front arc translated down `wall`."""
    return (f"M{n(CX - RX)} {n(cy)} A{n(RX)} {n(RY)} 0 0 1 {n(CX + RX)} {n(cy)} "
            f"L{n(CX + RX)} {n(cy + wall)} A{n(RX)} {n(RY)} 0 0 1 {n(CX - RX)} {n(cy + wall)} Z")


def wall_stops(col):
    return (stop(0, col["wall_light"]) + stop(0.45, col["wall_mid"])
            + stop(1, col["wall_deep"]))


def mask_points():
    """Blend weights m(dx) = 1-sqrt(1-(dx/rx)^2): mixing the edge-anchored ramp
    in with this weight reproduces the arc-following ramp exactly."""
    pts = []
    for off in (0, 0.25, 0.375, 0.5, 0.625, 0.75, 1):
        t = abs(2 * off - 1)
        pts.append((off, 1 - math.sqrt(max(0.0, 1 - t * t))))
    return pts


def edge_shade_points():
    """Cylindrical darkening toward the rim, sampled from 0.28*(1-(1-t^2)^0.85)."""
    pts = []
    for off in (0, 0.25, 0.375, 0.5, 0.625, 0.75, 1):
        t = abs(2 * off - 1)
        pts.append((off, 0.28 * (1 - max(0.0, 1 - t * t) ** 0.85)))
    return pts


def wall_defs(pid, cy, wall, col):
    """Gradients + mask shading one side wall: center ramp, edge ramp blended
    by the arc mask, then the rim-darkening overlay."""
    y_a0, y_b0 = cy + RY, cy
    d = [
        linear(f"{pid}wa", CX, y_a0, CX, y_a0 + wall, wall_stops(col)),
        linear(f"{pid}wb", CX, y_b0, CX, y_b0 + wall, wall_stops(col)),
        linear(f"{pid}wg", CX - RX, 0, CX + RX, 0,
               "".join(stop(o, "#fff", v) for o, v in mask_points())),
        f'<mask id="{pid}wm" maskUnits="userSpaceOnUse" x="{n(CX - RX)}" y="{n(cy)}" '
        f'width="{n(2 * RX)}" height="{n(wall + RY)}">'
        f'<rect x="{n(CX - RX)}" y="{n(cy)}" width="{n(2 * RX)}" height="{n(wall + RY)}" '
        f'fill="url(#{pid}wg)"/></mask>',
        linear(f"{pid}wo", CX - RX, 0, CX + RX, 0,
               "".join(stop(o, "#000", v) for o, v in edge_shade_points())),
    ]
    return d


def wall_body(pid, path):
    return [f'<path d="{path}" fill="url(#{pid}wa)"/>',
            f'<path d="{path}" fill="url(#{pid}wb)" mask="url(#{pid}wm)"/>',
            f'<path d="{path}" fill="url(#{pid}wo)"/>']


def contact_shadow(pid, y_src, clip_id):
    """AO under a slab: two wide flat Gaussians clipped to the layer below
    (0.30 strength split 0.6/0.4, as in the numpy build)."""
    defs = []
    els = [f'<g clip-path="url(#{clip_id})">']
    for i, (dy, sx, sy, w) in enumerate([(6, 0.60, 14, 0.6), (14, 0.78, 24, 0.4)]):
        g, e = blob(f"{pid}b{i}", CX, y_src + dy, RX * sx, sy, w * 0.30, AO_RGB)
        defs.append(g)
        els.append(e)
    els.append("</g>")
    return defs, "".join(els)


# ---- R mark ----

def mul(m, b):
    """Compose affine transforms: mul(a, b) applies b first. SVG order (a,b,c,d,e,f)."""
    return (m[0] * b[0] + m[2] * b[1], m[1] * b[0] + m[3] * b[1],
            m[0] * b[2] + m[2] * b[3], m[1] * b[2] + m[3] * b[3],
            m[0] * b[4] + m[2] * b[5] + m[4], m[1] * b[4] + m[3] * b[5] + m[5])


def apply(m, x, y):
    return (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5])


def _flatten_quad(p0, p1, p2, n=8):
    return [((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0],
             (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1])
            for t in (i / n for i in range(1, n + 1))]


def _flatten_cubic(p0, p1, p2, p3, n=8):
    return [((1 - t) ** 3 * p0[0] + 3 * (1 - t) ** 2 * t * p1[0] + 3 * (1 - t) * t * t * p2[0] + t ** 3 * p3[0],
             (1 - t) ** 3 * p0[1] + 3 * (1 - t) ** 2 * t * p1[1] + 3 * (1 - t) * t * t * p2[1] + t ** 3 * p3[1])
            for t in (i / n for i in range(1, n + 1))]


def outline_points(glyph, glyph_set):
    """Flattened outline in font units (y-up): the rotated ink's true bbox comes
    from these, since rotating the bbox rectangle overestimates its extremes."""
    pen = RecordingPen()
    glyph.draw(pen)
    pts = []
    for op, args in pen.value:
        if op in ("moveTo", "lineTo"):
            pts.append(args[0])
        elif op == "qCurveTo":
            seq = list(args)
            cur, offs, on = pts[-1], seq[:-1], seq[-1]
            for i, off in enumerate(offs):
                nxt = offs[i + 1] if i + 1 < len(offs) else on
                mid = ((off[0] + nxt[0]) / 2, (off[1] + nxt[1]) / 2)
                pts.extend(_flatten_quad(cur, off, mid if i + 1 < len(offs) else on))
                cur = pts[-1]
        elif op == "curveTo":
            pts.extend(_flatten_cubic(pts[-1], *args))
    return pts


def load_bold_font():
    for path in ["/System/Library/Fonts/Helvetica.ttc",
                 "/System/Library/Fonts/HelveticaNeue.ttc",
                 "/Library/Fonts/Arial Bold.ttf",
                 "/System/Library/Fonts/Supplemental/Arial Bold.ttf"]:
        try:
            fonts = TTCollection(path, lazy=True).fonts
        except Exception:
            try:
                fonts = [TTFont(path, lazy=True)]
            except Exception:
                continue
        for f in fonts:
            style = f["name"].getDebugName(2) or ""
            if "bold" in style.lower():
                return f
    raise SystemExit("no bold font found")


def r_mark(spin, ratio, font_size, face_cy):
    """White R as a glyph outline path, rotated in the disc plane then
    foreshortened, final ink bbox centered on the face (like the numpy build)."""
    font = load_bold_font()
    glyph_set = font.getGlyphSet()
    glyph = glyph_set[font.getBestCmap()[ord("R")]]
    spen = SVGPathPen(glyph_set)
    glyph.draw(spen)
    k = font_size / font["head"].unitsPerEm

    m = (1, 0, 0, 1, CX / 2, 0)                                # pivot: irrelevant to the final bbox
    m = mul((k, 0, 0, -k, 0, 0), m)                            # em -> px, y-down
    a = math.radians(-spin)                                    # SVG rotate is CW
    m = mul((math.cos(a), math.sin(a), -math.sin(a), math.cos(a), 0, 0), m)
    m = mul((1, 0, 0, ratio, 0, 0), m)                         # foreshorten
    pts = [apply(m, x, y) for x, y in outline_points(glyph, glyph_set)]
    bx = (min(p[0] for p in pts) + max(p[0] for p in pts)) / 2
    by = (min(p[1] for p in pts) + max(p[1] for p in pts)) / 2
    m = mul((1, 0, 0, 1, CX - bx, face_cy + FACE_DY - by), m)
    return (f'<g transform="matrix({n(m[0])} {n(m[1])} {n(m[2])} {n(m[3])} '
            f'{n(m[4])} {n(m[5])})"><path d="{spen.getCommands()}" fill="#FFFFFF"/></g>')


# ---- composition ----

def build_svg(gap: float, spin: float, ratio: float, font_size: float) -> str:
    wall = (STACK_H - 2 * RY - 2 * gap) / 3    # equal wall budget per layer
    red_cy = CX + RY - STACK_H / 2             # stack vertically centered
    yellow_cy = red_cy + wall + gap            # virtual face center of the band
    blue_cy = yellow_cy + wall + gap
    red_bottom = red_cy + wall + RY
    yellow_bottom = yellow_cy + wall + RY
    stack_bottom = blue_cy + wall + RY
    y_ground = CX + (stack_bottom - CX) * STACK_SCALE

    defs = [
        f'<clipPath id="tile"><rect x="0" y="0" width="{OUT}" height="{OUT}" rx="{TILE_R}"/></clipPath>',
        linear("bg", 0, 0, 0, OUT, stop(0, BG_TOP) + stop(1, BG_BOT)),
        f'<clipPath id="sil-y"><path d="{cylinder_path(yellow_cy, wall)}"/></clipPath>',
        f'<clipPath id="sil-b"><path d="{cylinder_path(blue_cy, wall)}"/></clipPath>',
    ]
    defs += wall_defs("r", red_cy, wall, RED)
    defs += wall_defs("y", yellow_cy, wall, YELLOW)
    defs += wall_defs("b", blue_cy, wall, BLUE)

    # top face: ramp along (0.52, 0.85), clamps at t=-1.1 / +0.9 of the 1.1*rx span
    p0, p1 = -1.21 * RX, 0.99 * RX
    defs.append(linear("face", CX + p0 * 0.52, red_cy + p0 * 0.85,
                       CX + p1 * 0.52, red_cy + p1 * 0.85,
                       stop(0, RED["face_light"]) + stop(1, RED["face_deep"])))

    body = [f'<rect x="0" y="0" width="{OUT}" height="{OUT}" fill="url(#bg)"/>']
    for i, (dy, sx, sy) in enumerate([(30, 0.70, 34), (40, 0.88, 54)]):
        g, e = blob(f"gr{i}", CX, y_ground + dy, RX * sx * STACK_SCALE, sy,
                    0.5 * 0.26, GROUND_RGB)
        defs.append(g)
        body.append(e)

    stack = []
    stack += wall_body("b", band_path(blue_cy, wall))
    ao1_defs, ao1 = contact_shadow("ay", yellow_bottom, "sil-b")
    defs += ao1_defs
    stack.append(ao1)
    stack += wall_body("y", band_path(yellow_cy, wall))
    ao2_defs, ao2 = contact_shadow("ar", red_bottom, "sil-y")
    defs += ao2_defs
    stack.append(ao2)
    stack += wall_body("r", cylinder_path(red_cy, wall))
    stack.append(f'<ellipse cx="{n(CX)}" cy="{n(red_cy)}" rx="{n(RX)}" ry="{n(RY)}" fill="url(#face)"/>')
    stack.append(r_mark(spin, ratio, font_size, red_cy))
    scale = (f"translate({n(CX)} {n(CX)}) scale({STACK_SCALE}) translate({n(-CX)} {n(-CX)})")
    body.append(f'<g transform="{scale}">{"".join(stack)}</g>')

    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{OUT}" height="{OUT}" '
            f'viewBox="0 0 {OUT} {OUT}"><defs>{"".join(defs)}</defs>'
            f'<g clip-path="url(#tile)">{"".join(body)}</g></svg>')


def render_master(svg: str) -> Image.Image:
    png = resvg_py.svg_to_bytes(svg_string=svg, width=RENDER_PX, height=RENDER_PX)
    return Image.open(io.BytesIO(png)).convert("RGBA").resize((OUT, OUT), Image.LANCZOS)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--gap", type=float, default=GAP,
                    help="slot between the layers in 1024-space")
    ap.add_argument("--spin", type=float, default=SPIN, help="R in-plane rotation, deg CCW")
    ap.add_argument("--ratio", type=float, default=RATIO, help="face foreshortening (ry/rx)")
    ap.add_argument("--font-size", type=float, default=FONT_SIZE, help="R em size in 1024-space")
    ap.add_argument("--preview", type=str, default="/tmp/runlet_icon_master.png",
                    help="also write the 1024 master to this path")
    args = ap.parse_args()

    master = render_master(build_svg(args.gap, args.spin, args.ratio, args.font_size))
    for name, s in SIZES.items():
        img = master if s == OUT else master.resize((s, s), Image.LANCZOS)
        img.save(ICONSET / name)
    if args.preview:
        master.save(args.preview)
    print(f"wrote {len(SIZES)} sizes to {ICONSET}"
          + (f", preview {args.preview}" if args.preview else ""))


if __name__ == "__main__":
    sys.exit(main())
