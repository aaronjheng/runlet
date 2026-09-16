# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow", "numpy"]
# ///
"""Generate the Runlet app icon (all 10 AppIcon sizes).

Design: 3-layer disc stack measured from the Sequel Ace icon (disc radius,
ellipse ratio, wall heights, gaps, stack position); stack colors sampled from
the original icon in commit b6c40c61 (vivid red/yellow/blue); light
background from the previous generation; the R mark is painted onto the top
face: the glyph is first rotated inside
the disc plane (like a bucket spinning in place), then foreshortened
vertically by the face's ry/rx ratio, so it reads as lying on the disc.

Usage:
    uv run Tools/gen_appicon.py [--spin 25] [--ratio 0.333] [--font-size 340]
                                [--preview /tmp/icon_master.png]

Writes the 10 PNGs into Assets.xcassets/Runlet.appiconset/ by default.
"""
import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "Assets.xcassets" / "Runlet.appiconset"

# ---- geometry (1024-space), measured from Sequel Ace's AppIcon ----
SS = 2                       # supersample factor
OUT = 1024
BG_BOX = (100, 100, 924, 924)
BG_R = 225
CX = 512
RX, RY = 282, 94             # disc ellipse (ry/rx = 0.333)
WALL_TOP = 93                # top disc side wall
WALL_THIN = 95               # thin band wall
RED_CY = 322                 # top face ellipse center (back edge at y=228)
BAND1_E = 556 - RY           # thin band: virtual face center (top arc y=556)
BAND2_E = 700 - RY           # (top arc y=700)
STACK_SCALE = 1.28           # grow the stack to fill the full-bleed canvas (b6 fill factor)

# ---- palette: sampled from the icon in commit b6c40c61 ----
def C(hexs):
    return np.array([int(hexs[i:i+2], 16) for i in (0, 2, 4)], np.float32)

BG_GRAD_TOP = C("F7F8FA")
BG_GRAD_BOT = C("EDEFF3")
RED = dict(face_light=C("F8615F"), face_deep=C("E14036"),
           wall_light=C("EE534E"), wall_mid=C("E94B44"), wall_deep=C("E03E37"))
YELLOW = dict(face_light=C("F6AD26"), face_deep=C("F5A824"),
              wall_light=C("F6AD26"), wall_mid=C("F8B82C"), wall_deep=C("F5A824"))
BLUE = dict(face_light=C("55A3B9"), face_deep=C("4B92D6"),
            wall_light=C("55A3B9"), wall_mid=C("509BC7"), wall_deep=C("4B92D6"))

SIZES = {"icon_512x512@2x.png": 1024, "icon_512x512.png": 512,
         "icon_256x256@2x.png": 512, "icon_256x256.png": 256,
         "icon_128x128@2x.png": 256, "icon_128x128.png": 128,
         "icon_32x32@2x.png": 64, "icon_32x32.png": 32,
         "icon_16x16@2x.png": 32, "icon_16x16.png": 16}

W = OUT * SS
_y, _x = np.mgrid[0:W, 0:W].astype(np.float32)
Xf, Yf = _x / SS, _y / SS


def over(canvas, mask, rgb):
    m = mask[..., None]
    col = np.asarray(rgb, np.float32)
    if col.ndim == 1:
        col = np.broadcast_to(col, canvas[0].shape)
    canvas[0] = col * m + canvas[0] * (1 - m)
    canvas[1] = mask + canvas[1] * (1 - mask)


def rounded_rect_mask(box, r):
    img = Image.new("L", (W, W), 0)
    ImageDraw.Draw(img).rounded_rectangle([v * SS for v in box], radius=r * SS, fill=255)
    return np.asarray(img, np.float32) / 255


def ellipse_soft(cx, cy, rx, ry, soft=1.2):
    rho = np.sqrt(((Xf - cx) / rx) ** 2 + ((Yf - cy) / ry) ** 2)
    return np.clip((1 - rho) * min(rx, ry) / soft / SS, 0, 1)


def gauss_blob(cx, cy, sx, sy, rot=0.0):
    a = np.deg2rad(rot)
    dx, dy = Xf - cx, Yf - cy
    u = dx * np.cos(a) + dy * np.sin(a)
    v = -dx * np.sin(a) + dy * np.cos(a)
    return np.exp(-(u ** 2 / (2 * sx ** 2) + v ** 2 / (2 * sy ** 2)))


def wall_gradient(u, col):
    light, mid, deep = col["wall_light"], col["wall_mid"], col["wall_deep"]
    k = 0.45
    a = (u <= k)[..., None] * (light + (mid - light) * (u / k)[..., None])
    b = (u > k)[..., None] * (mid + (deep - mid) * ((u - k) / (1 - k))[..., None])
    return a + b


def draw_disc(canvas, cy, wall, col, face):
    """Cylinder at face-center cy. Bands pass face=False (no top face drawn)."""
    dx = Xf - CX
    arc = np.sqrt(np.clip(1 - (dx / RX) ** 2, 0, 1))
    sil = (np.clip((RX - np.abs(dx)) / (1.2 * SS), 0, 1)
           * np.clip((Yf - (cy - RY * arc)) / (1.2 * SS), 0, 1)
           * np.clip(((cy + wall + RY * arc) - Yf) / (1.2 * SS), 0, 1))
    y_wall_top = cy + RY * arc          # wall starts at the front arc of the top face
    u = np.clip((Yf - y_wall_top) / wall, 0, 1)
    wall_m = sil * np.clip((Yf - y_wall_top) / (1.2 * SS) + 1e-4, 0, 1) * (u < 1)
    if not face:                        # hide everything above the front arc
        wall_m = sil * (Yf >= y_wall_top - 0.5)
    xf = 0.72 + 0.28 * np.clip(1 - (dx / RX) ** 2, 0, 1) ** 0.85
    over(canvas, wall_m, np.clip(wall_gradient(u, col) * xf[..., None], 0, 255))
    if face:                            # face painted after the wall: no alpha seam
        fm = ellipse_soft(CX, cy, RX, RY) * sil
        t = np.clip(((Xf - CX) * 0.52 + (Yf - cy) * 0.85) / (RX * 1.1), -1, 1) * 0.5 + 0.55
        over(canvas, fm, col["face_light"] + (col["face_deep"] - col["face_light"]) * t[..., None])
    return sil


def draw_ao(canvas, y_src, lower_sil):
    """Contact shadow under a slab, clipped to the layer below."""
    g = gauss_blob(CX, y_src + 6, RX * 0.60, 14) * 0.60 + gauss_blob(CX, y_src + 14, RX * 0.78, 24) * 0.40
    over(canvas, np.clip(g, 0, 1) * lower_sil * 0.30, np.array([30, 24, 34], np.float32))


def load_bold(size):
    for path, idx in [("/System/Library/Fonts/Helvetica.ttc", 1),
                      ("/System/Library/Fonts/HelveticaNeue.ttc", 1),
                      ("/Library/Fonts/Arial Bold.ttf", 0),
                      ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 0)]:
        try:
            f = ImageFont.truetype(path, size, index=idx)
            if "bold" in f.getname()[1].lower():
                return f
        except Exception:
            continue
    raise SystemExit("no bold font found")


def build(spin: float, ratio: float, font_size: float) -> Image.Image:
    bg = [np.zeros((W, W, 3), np.float32), np.zeros((W, W), np.float32)]
    st = [np.zeros((W, W, 3), np.float32), np.zeros((W, W), np.float32)]
    # full-bleed background: macOS 27 masks the squircle itself, so fill the canvas
    bg_t = (Yf / OUT)[..., None]
    over(bg, np.ones((W, W), np.float32), BG_GRAD_TOP + (BG_GRAD_BOT - BG_GRAD_TOP) * bg_t)
    y_ground = 512 + (BAND2_E + WALL_THIN + RY - 512) * STACK_SCALE
    g = gauss_blob(CX, y_ground + 30, RX * 0.70 * STACK_SCALE, 34) * 0.5 + gauss_blob(CX, y_ground + 40, RX * 0.88 * STACK_SCALE, 54) * 0.5
    over(bg, np.clip(g, 0, 1) * 0.26, np.array([52, 58, 76], np.float32))

    # painter order: bottom band -> AO -> middle band -> AO -> top disc
    blue_sil = draw_disc(st, BAND2_E, WALL_THIN, BLUE, face=False)
    draw_ao(st, BAND1_E + WALL_THIN + RY, blue_sil)
    orange_sil = draw_disc(st, BAND1_E, WALL_THIN, YELLOW, face=False)
    draw_ao(st, RED_CY + WALL_TOP + RY, orange_sil)
    draw_disc(st, RED_CY, WALL_TOP, RED, face=True)

    stack = Image.fromarray(np.dstack([
        np.clip(st[0], 0, 255).astype(np.uint8),
        np.clip(st[1] * 255, 0, 255).astype(np.uint8)]), "RGBA")

    # R mark: rotate in the disc plane (bucket spin), then foreshorten by ry/rx
    font = load_bold(int(font_size * SS))
    tile = Image.new("RGBA", (int(font_size * SS * 2.4),) * 2, (0, 0, 0, 0))
    ImageDraw.Draw(tile).text((tile.width // 2, tile.height // 2), "R",
                              font=font, fill=(255, 255, 255, 255), anchor="mm")
    tile = tile.crop(tile.getbbox())
    tile = tile.rotate(spin, expand=True, resample=Image.BICUBIC)   # in-plane spin
    tile = tile.crop(tile.getbbox())
    tw, th = tile.size
    nh = max(2, int(th * ratio))                                    # foreshorten
    tile = tile.resize((tw, nh), Image.LANCZOS)
    stack.alpha_composite(tile, (int(CX * SS - tw / 2), int((RED_CY + 2) * SS - nh / 2)))
    if STACK_SCALE != 1.0:
        scaled_w = round(W * STACK_SCALE)
        stack = stack.resize((scaled_w, scaled_w), Image.LANCZOS)
        stack_frame = Image.new("RGBA", (W, W), (0, 0, 0, 0))
        stack_frame.paste(stack, ((W - scaled_w) // 2, (W - scaled_w) // 2), stack)
    else:
        stack_frame = stack

    img = Image.fromarray(np.dstack([
        np.clip(bg[0], 0, 255).astype(np.uint8),
        np.clip(bg[1] * 255, 0, 255).astype(np.uint8)]), "RGBA")
    img.alpha_composite(stack_frame)
    # legacy-format icons render as-is: bake the rounded corners (radius from the b6 reference)
    corner_mask = rounded_rect_mask((0, 0, OUT, OUT), 170)
    img.putalpha(Image.fromarray((corner_mask * 255).astype(np.uint8)))
    return img.resize((OUT, OUT), Image.LANCZOS)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--spin", type=float, default=25.0, help="R in-plane rotation, deg CCW")
    ap.add_argument("--ratio", type=float, default=RY / RX, help="face foreshortening (ry/rx)")
    ap.add_argument("--font-size", type=float, default=340.0, help="R font size in 1024-space")
    ap.add_argument("--preview", type=str, default="/tmp/runlet_icon_master.png",
                    help="also write the 1024 master to this path")
    args = ap.parse_args()

    master = build(args.spin, args.ratio, args.font_size)
    for name, s in SIZES.items():
        img = master if s == OUT else master.resize((s, s), Image.LANCZOS)
        img.save(ICONSET / name)
    if args.preview:
        master.save(args.preview)
    print(f"wrote {len(SIZES)} sizes to {ICONSET}" + (f", preview {args.preview}" if args.preview else ""))


if __name__ == "__main__":
    sys.exit(main())
