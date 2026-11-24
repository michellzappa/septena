#!/usr/bin/env python3
"""
Photo composite: put a real app screenshot on the device in a photo.
Technique and steps: docs/photo-composite/SKILL.md.

The photo `X.png` needs a sidecar `X.screen.json` with the screen corners
(TL, TR, BR, BL, normalized, origin top-left), the corner radius as a fraction
of the screen width, and the SHA-256 of the photo. The script stops when the
sidecar is missing or the photo is not the measured one, so a changed photo
never gets a screenshot in the wrong place.

Runs in Blender's bundled Python + NumPy (no extra packages): a projective
warp with 4x4 linear-light supersampling, a continuous-curvature corner mask,
and light matching (black floor, white point, falloff, sheen, grain).

Composite:
  blender -b --python-exit-code 1 --python tools/3d-studio/replace_photo_screen.py -- \
    --photo appstore/art/photo-today.png --ios SCREEN.png --out OUT.png

New photo (paint its own screen black, then pin the new hash in the sidecar):
  blender -b --python-exit-code 1 --python tools/3d-studio/replace_photo_screen.py -- \
    --photo X.png --blackout
"""
import argparse
import hashlib
import json
import os
import sys
import bpy
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
DEFAULT_PHOTO = os.path.join(REPO_ROOT, "appstore", "art", "photo-today.png")
DEFAULT_IOS = os.path.join(SCRIPT_DIR, "screens", "demo_ios.png")
DEFAULT_OUT = os.path.join(SCRIPT_DIR, "renders", "photo_today_replaced.png")

SQUIRCLE_POWER = 2.65


def parse_args():
    argv = sys.argv
    if "--" in argv:
        argv = argv[argv.index("--") + 1:]
    else:
        argv = []
    p = argparse.ArgumentParser(description="Replace iPhone screen in photo-today.png with a real screenshot")
    p.add_argument("--photo", default=DEFAULT_PHOTO, help="Base photograph path")
    p.add_argument("--ios", default=DEFAULT_IOS, help="Real app screenshot PNG/JPG")
    p.add_argument("--blackout", action="store_true", help="Paint the photo's own screen black in place and pin its hash in the sidecar")
    p.add_argument("--out", default=DEFAULT_OUT, help="Output composited PNG path")
    p.add_argument("--inset-px", type=float, default=-0.5, help="Expand/contract screen mask in pixels (negative = slightly wider into bezel)")
    p.add_argument("--feather-px", type=float, default=1.25, help="Anti-aliased edge blend width in pixels")
    p.add_argument("--black-floor", type=float, default=0.026, help="Ambient OLED black-level lift (sRGB 0..1)")
    p.add_argument("--white-point", type=float, default=0.955, help="Matched OLED peak white exposure (sRGB 0..1)")
    p.add_argument("--glare", type=float, default=0.022, help="Subtle diagonal glossy window reflection intensity")
    p.add_argument("--grain", type=float, default=0.005, help="Matching photographic luma grain sigma")
    p.add_argument("--ssaa", type=int, default=4, help="Supersampling grid per axis (4 = 16 samples/px)")
    return p.parse_args(argv)


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def load_screen(photo_path, check_hash=True):
    """Read and check the photo's sidecar. Exits when it cannot be trusted."""
    side = os.path.splitext(photo_path)[0] + ".screen.json"
    if not os.path.exists(side):
        sys.exit(f"replace_photo_screen: {side} is missing. Measure the photo first (docs/photo-composite/SKILL.md).")
    with open(side) as f:
        meta = json.load(f)
    corners = np.asarray(meta["corners"], dtype=np.float64)
    if corners.shape != (4, 2) or corners.min() < 0.0 or corners.max() > 1.0:
        sys.exit(f"replace_photo_screen: {side} needs 4 corners in 0..1")
    if check_hash and meta.get("sha256") != sha256(photo_path):
        sys.exit(f"replace_photo_screen: {photo_path} is not the photo {side} was measured on. Measure it again.")
    return side, meta, corners, float(meta["cornerRadius"])


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, np.power(np.clip((c + 0.055) / 1.055, 0.0, 1.0), 2.4))


def linear_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1.0 / 2.4) - 0.055)


def compute_homography(src_pts, dst_pts):
    """Solve 3x3 projective homography H such that H @ [x, y, 1]^T ~ [u, v, 1]^T."""
    A = []
    for (x, y), (u, v) in zip(src_pts, dst_pts):
        A.append([-x, -y, -1.0,  0.0,  0.0,  0.0, u * x, u * y, u])
        A.append([ 0.0,  0.0,  0.0, -x, -y, -1.0, v * x, v * y, v])
    A = np.asarray(A, dtype=np.float64)
    _, _, Vt = np.linalg.svd(A)
    H = Vt[-1].reshape(3, 3)
    return H / H[2, 2]


def bilinear_sample(img_lin, u, v):
    """Sample HxWx3 linear image at normalized UV coordinates (u in [0,1], v in [0,1], top-left origin)."""
    sh, sw, _ = img_lin.shape
    fx = np.clip(u, 0.0, 1.0) * (sw - 1.0)
    fy = np.clip(v, 0.0, 1.0) * (sh - 1.0)
    x0 = np.floor(fx).astype(np.int32)
    y0 = np.floor(fy).astype(np.int32)
    x1 = np.minimum(x0 + 1, sw - 1)
    y1 = np.minimum(y0 + 1, sh - 1)
    wx = (fx - x0)[..., None]
    wy = (fy - y0)[..., None]

    c00 = img_lin[y0, x0]
    c10 = img_lin[y0, x1]
    c01 = img_lin[y1, x0]
    c11 = img_lin[y1, x1]
    return (c00 * (1.0 - wx) + c10 * wx) * (1.0 - wy) + (c01 * (1.0 - wx) + c11 * wx) * wy


def squircle_sdf(u, v, aspect, r_u, power=2.65):
    """Signed distance (in screen-width units; negative = inside) to a continuous-curvature rounded rect."""
    # Map UV to centered coordinates where width = 1.0 and height = aspect
    px = np.abs(u - 0.5)
    py = np.abs(v - 0.5) * aspect
    bx = 0.5 - r_u
    by = 0.5 * aspect - r_u
    qx = np.maximum(px - bx, 0.0)
    qy = np.maximum(py - by, 0.0)
    # Superellipse corner distance for authentic iOS squircle curvature
    corner_d = np.power(np.power(qx, power) + np.power(qy, power), 1.0 / power)
    inside_d = np.minimum(np.maximum(px - 0.5, py - 0.5 * aspect), 0.0)
    # Only use inside_d when not in corner region
    in_corner = (qx > 0.0) & (qy > 0.0)
    dist = np.where(in_corner, corner_d - r_u, np.maximum(px - 0.5, py - 0.5 * aspect))
    return dist


def load_image_topdown_srgb(path):
    """Load PNG/JPG via Blender as float32 HxWx4 sRGB array with row 0 at TOP."""
    img = bpy.data.images.load(os.path.abspath(path), check_existing=False)
    w, h = img.size
    arr = np.array(img.pixels[:], dtype=np.float32).reshape((h, w, 4))[::-1, :, :].copy()
    bpy.data.images.remove(img)
    return arr


def save_image_topdown_srgb(arr_srgb, out_path):
    """Save float32 HxWx3 or HxWx4 sRGB array (top-down) cleanly as lossless RGB PNG."""
    h, w = arr_srgb.shape[:2]
    rgba = np.ones((h, w, 4), dtype=np.float32)
    rgba[:, :, :3] = np.clip(arr_srgb[:, :, :3], 0.0, 1.0)
    # Flip back to Blender bottom-up row order
    flat = rgba[::-1, :, :].ravel()

    out_img = bpy.data.images.new("CompositedPhoto", width=w, height=h, alpha=False, float_buffer=False)
    out_img.colorspace_settings.name = 'sRGB'
    out_img.pixels.foreach_set(flat)
    out_img.filepath_raw = os.path.abspath(out_path)
    out_img.file_format = 'PNG'
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    out_img.save()
    bpy.data.images.remove(out_img)


def blackout(photo_path, photo, side, meta, corners, corner_radius):
    """Remove the photo's own screen: paint it black, 1 px past the edge, so no
    generated UI is left to show. Then pin the new file's hash."""
    ph, pw, _ = photo.shape
    quad_px = corners * np.array([[pw, ph]], dtype=np.float64)
    H = compute_homography(quad_px, np.array([[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]))
    gx, gy = np.meshgrid(np.arange(pw) + 0.5, np.arange(ph) + 0.5)
    d = H[2, 0] * gx + H[2, 1] * gy + H[2, 2]
    u = (H[0, 0] * gx + H[0, 1] * gy + H[0, 2]) / d
    v = (H[1, 0] * gx + H[1, 1] * gy + H[1, 2]) / d
    w = 0.5 * (np.linalg.norm(quad_px[1] - quad_px[0]) + np.linalg.norm(quad_px[2] - quad_px[3]))
    h = 0.5 * (np.linalg.norm(quad_px[3] - quad_px[0]) + np.linalg.norm(quad_px[2] - quad_px[1]))
    sdf_px = squircle_sdf(u, v, h / w, corner_radius, power=SQUIRCLE_POWER) * w
    # Solid black to 1 px outside the edge, then a 1 px soft step into the bezel.
    keep = np.clip(sdf_px - 1.0, 0.0, 1.0)
    out = photo[:, :, :3] * np.where(d > 0, keep, 1.0)[..., None]
    save_image_topdown_srgb(out, photo_path)
    meta["sha256"] = sha256(photo_path)
    with open(side, "w") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")
    print(f"Screen painted black in {photo_path}; hash pinned in {side}")


def main():
    args = parse_args()
    side, meta, corners, corner_radius = load_screen(args.photo, check_hash=not args.blackout)
    photo = load_image_topdown_srgb(args.photo)
    if args.blackout:
        blackout(args.photo, photo, side, meta, corners, corner_radius)
        return
    screen = load_image_topdown_srgb(args.ios)

    ph, pw, _ = photo.shape
    sh, sw, _ = screen.shape
    screen_aspect = float(sh) / float(sw)
    print(f"Base photo: {pw}x{ph} | Screenshot: {sw}x{sh} (aspect={screen_aspect:.4f})")

    # Exact quad corners in base photo pixel coordinates
    quad_px = corners * np.array([[pw, ph]], dtype=np.float64)
    uv_corners = np.array([
        [0.0, 0.0],  # TL
        [1.0, 0.0],  # TR
        [1.0, 1.0],  # BR
        [0.0, 1.0],  # BL
    ], dtype=np.float64)

    # Homography mapping base-photo pixel (x, y) -> screenshot normalized UV (u, v)
    H = compute_homography(quad_px, uv_corners)

    # Bounding box around phone screen with margin
    pad = 8
    x_min = max(0, int(np.floor(quad_px[:, 0].min())) - pad)
    x_max = min(pw, int(np.ceil(quad_px[:, 0].max())) + pad)
    y_min = max(0, int(np.floor(quad_px[:, 1].min())) - pad)
    y_max = min(ph, int(np.ceil(quad_px[:, 1].max())) + pad)

    roi_w = x_max - x_min
    roi_h = y_max - y_min
    mean_scr_w = 0.5 * (
        np.linalg.norm(quad_px[1] - quad_px[0]) + np.linalg.norm(quad_px[2] - quad_px[3])
    )

    # Convert source screenshot to linear light once for physically accurate supersampling
    screen_lin = srgb_to_linear(screen[:, :, :3].astype(np.float64))

    # Build pixel center grid in ROI
    xs = np.arange(x_min, x_max, dtype=np.float64) + 0.5
    ys = np.arange(y_min, y_max, dtype=np.float64) + 0.5
    gx, gy = np.meshgrid(xs, ys)

    # 4x4 stratified supersampling (with subtle 0.35px optical softness to match real camera optics)
    n = max(1, args.ssaa)
    offsets = (np.arange(n, dtype=np.float64) + 0.5) / n - 0.5
    # Slight optical kernel spread (1.12x pixel pitch) gives subtle natural lens softening without blurring text
    offsets *= 1.12

    accum_lin = np.zeros((roi_h, roi_w, 3), dtype=np.float64)
    for oy in offsets:
        for ox in offsets:
            sx = gx + ox
            sy = gy + oy
            denom = H[2, 0] * sx + H[2, 1] * sy + H[2, 2]
            u = (H[0, 0] * sx + H[0, 1] * sy + H[0, 2]) / denom
            v = (H[1, 0] * sx + H[1, 1] * sy + H[1, 2]) / denom
            accum_lin += bilinear_sample(screen_lin, u, v)
    accum_lin /= float(n * n)

    # Compute center UV for mask, ambient illumination, and subtle glass reflection
    denom_c = H[2, 0] * gx + H[2, 1] * gy + H[2, 2]
    uc = (H[0, 0] * gx + H[0, 1] * gy + H[0, 2]) / denom_c
    vc = (H[1, 0] * gx + H[1, 1] * gy + H[1, 2]) / denom_c

    # Continuous-curvature rounded screen mask with crisp optical anti-aliasing into the black bezel
    sdf_px = squircle_sdf(uc, vc, screen_aspect, corner_radius, power=SQUIRCLE_POWER) * mean_scr_w
    # Smoothstep across [-feather, 0] shifted by inset_px
    edge = sdf_px - args.inset_px
    feather = max(0.5, args.feather_px)
    t = np.clip(-edge / feather, 0.0, 1.0)
    alpha = t * t * (3.0 - 2.0 * t)  # smoothstep: 1 inside screen, 0 on black bezel

    # Convert supersampled screenshot back to sRGB and match the photo's real OLED exposure & color cast
    warped_srgb = linear_to_srgb(accum_lin)

    # 1. Matched OLED black-floor (ambient room bounce on glass) and peak white-point
    warped_srgb = args.black_floor + warped_srgb * (args.white_point - args.black_floor)

    # 2. Subtle warm-neutral ambient illumination gradient (top-right catches slightly more window light)
    #    and whisper-soft edge vignette near the bezel rim
    illum = 0.965 + 0.045 * np.clip(uc * 0.65 + (1.0 - vc) * 0.55, 0.0, 1.0)
    bezel_ao = 1.0 - 0.035 * np.exp(np.clip(sdf_px / 6.0, -10.0, 0.0))
    warped_srgb *= (illum * bezel_ao)[..., None]

    # 3. Very subtle warm-cream color balance matching a photographed OLED
    warped_srgb *= np.array([1.000, 0.994, 0.986], dtype=np.float64)[None, None, :]

    # 4. Subtle diagonal glossy glass reflection band (upper-right window sheen)
    if args.glare > 0.0:
        diag = (uc * 0.85 - vc * 0.55 + 0.15)
        sheen = np.exp(-((diag - 0.35) ** 2) / 0.14) * np.clip(1.1 - vc * 0.8, 0.0, 1.0)
        warped_srgb = np.clip(warped_srgb + args.glare * sheen[..., None], 0.0, 1.0)

    # 5. Subtle matching photographic micro-grain (deterministic seed)
    if args.grain > 0.0:
        rng = np.random.default_rng(42)
        noise = rng.normal(0.0, args.grain, size=(roi_h, roi_w, 1))
        warped_srgb = np.clip(warped_srgb + noise, 0.0, 1.0)

    # Composite cleanly into base photo ROI
    out = photo[:, :, :3].astype(np.float64).copy()
    roi_bg = out[y_min:y_max, x_min:x_max]
    a3 = alpha[..., None]
    out[y_min:y_max, x_min:x_max] = roi_bg * (1.0 - a3) + warped_srgb * a3

    save_image_topdown_srgb(out.astype(np.float32), args.out)
    print(f"Saved replaced screen photo -> {args.out}")


if __name__ == "__main__":
    main()
