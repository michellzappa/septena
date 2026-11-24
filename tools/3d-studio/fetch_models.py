#!/usr/bin/env python3
"""
Download the pinned free Royalty-Free Apple device .blend models from BlenderKit's
public free-asset API into tools/3d-studio/models/ (gitignored).

Usage:
  python3 tools/3d-studio/fetch_models.py
"""
import json
import os
import urllib.request
import uuid

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(SCRIPT_DIR, "models")

# Pinned free Royalty-Free BlenderKit assets (native .blend, real-world meter scale)
MODELS = [
    # Apple ecosystem
    ("macbook_pro_14_2024.blend",   "https://www.blenderkit.com/api/v1/downloads/a1c7b4c4-971c-4beb-b084-5c7ec299e488/"),
    ("ipad_mini_space_grey.blend",  "https://www.blenderkit.com/api/v1/downloads/55fceb0a-a7e6-4e23-8bb2-fe74b517887d/"),
    ("iphone_17_pro_max.blend",     "https://www.blenderkit.com/api/v1/downloads/7cdf84c1-7540-4831-b37d-52c60f7d8107/"),
    ("iphone_17_air.blend",         "https://www.blenderkit.com/api/v1/downloads/939e2b79-cdb6-437f-bd34-73c7001fac37/"),
    ("smart_watch_2.blend",         "https://www.blenderkit.com/api/v1/downloads/0860d469-f503-4d25-aedc-ce055413f89f/"),
    # Windows + Android ecosystem
    ("windows_laptop_14.blend",     "https://www.blenderkit.com/api/v1/downloads/da914ce9-f1a4-477a-a6c4-915238034918/"),
    ("galaxy_book_2.blend",         "https://www.blenderkit.com/api/v1/downloads/0a176463-fa74-4238-af5d-aad560ca132a/"),
    ("galaxy_s25_ultra.blend",      "https://www.blenderkit.com/api/v1/downloads/4471c5bb-876c-4db5-ad58-36467b08660c/"),
    ("pixel_9_pro.blend",           "https://www.blenderkit.com/api/v1/downloads/1a562f83-291e-4eb8-98da-505bb630b921/"),
    ("galaxy_tablet.blend",         "https://www.blenderkit.com/api/v1/downloads/87c0e794-05cf-45a9-9ce0-b5addf029af9/"),
]


def download_model(filename: str, api_url: str) -> None:
    out_path = os.path.join(OUT_DIR, filename)
    if os.path.exists(out_path) and os.path.getsize(out_path) > 10_000:
        print(f"ok (cached): {filename} ({os.path.getsize(out_path):,} bytes)")
        return

    resolve_url = f"{api_url}?scene_uuid={uuid.uuid4()}"
    req = urllib.request.Request(resolve_url, headers={"User-Agent": "BlenderKit/3.0"})
    with urllib.request.urlopen(req, timeout=20) as r:
        info = json.loads(r.read().decode())
    file_url = info.get("filePath")
    if not file_url:
        raise RuntimeError(f"No filePath returned for {filename}: {info}")

    print(f"downloading: {filename} ...")
    req2 = urllib.request.Request(file_url, headers={"User-Agent": "BlenderKit/3.0"})
    tmp_path = out_path + ".part"
    with urllib.request.urlopen(req2, timeout=120) as r2, open(tmp_path, "wb") as f:
        while True:
            chunk = r2.read(65536)
            if not chunk:
                break
            f.write(chunk)
    os.replace(tmp_path, out_path)
    print(f"saved:       {filename} ({os.path.getsize(out_path):,} bytes)")


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    for filename, api_url in MODELS:
        download_model(filename, api_url)
    print(f"\nAll models ready in {OUT_DIR}")


if __name__ == "__main__":
    main()
