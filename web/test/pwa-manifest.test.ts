import { describe, it } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const PUBLIC_DIR = path.resolve(process.cwd(), "public");
const LAYOUT_PATH = path.resolve(process.cwd(), "src/app/layout.tsx");

function readPngDimensions(filePath: string): { width: number; height: number } {
  const buf = fs.readFileSync(filePath);
  assert.equal(
    buf.subarray(0, 8).toString("hex"),
    "89504e470d0a1a0a",
    `${path.basename(filePath)} must be a valid PNG`,
  );
  assert.equal(buf.subarray(12, 16).toString("ascii"), "IHDR");
  return {
    width: buf.readUInt32BE(16),
    height: buf.readUInt32BE(20),
  };
}

describe("PWA install and Home Screen metadata", () => {
  it("pins Android Install Septena to the web.septena.app root with valid PNG and maskable icons", () => {
    const manifestPath = path.join(PUBLIC_DIR, "manifest.webmanifest");
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8")) as {
      id?: string;
      name?: string;
      short_name?: string;
      start_url?: string;
      scope?: string;
      display?: string;
      prefer_related_applications?: boolean;
      icons?: Array<{ src: string; sizes?: string; type?: string; purpose?: string }>;
    };

    assert.equal(manifest.name, "Septena");
    assert.equal(manifest.short_name, "Septena");
    assert.equal(manifest.id, "/");
    assert.equal(manifest.start_url, "/");
    assert.equal(manifest.scope, "/");
    assert.equal(manifest.display, "standalone");
    assert.equal(manifest.prefer_related_applications, false);

    // Resolving start_url against web.septena.app must stay on https://web.septena.app/
    assert.equal(
      new URL(manifest.start_url!, "https://web.septena.app/manifest.webmanifest").href,
      "https://web.septena.app/",
    );

    const icons = manifest.icons ?? [];
    const png192 = icons.find((i) => i.type === "image/png" && i.sizes === "192x192");
    const png512 = icons.find((i) => i.type === "image/png" && i.sizes === "512x512" && i.purpose !== "maskable");
    const maskable512 = icons.find((i) => i.type === "image/png" && i.sizes === "512x512" && i.purpose === "maskable");

    assert.ok(png192, "manifest must include a 192x192 PNG icon for Android WebAPK");
    assert.ok(png512, "manifest must include a 512x512 PNG icon for Android WebAPK");
    assert.ok(maskable512, "manifest must include a 512x512 maskable PNG icon for Android adaptive icons");

    for (const icon of icons) {
      const assetPath = path.join(PUBLIC_DIR, icon.src.replace(/^\//, ""));
      assert.ok(fs.existsSync(assetPath), `manifest icon ${icon.src} must exist in public/`);
      if (icon.type === "image/png" && icon.sizes) {
        const [expectedW, expectedH] = icon.sizes.split("x").map(Number);
        const dims = readPngDimensions(assetPath);
        assert.deepEqual(dims, { width: expectedW, height: expectedH });
      }
    }
  });

  it("configures iOS Add to Home Screen with web.septena.app canonical metadata and 180x180 apple-touch-icon", () => {
    const appleIconPath = path.join(PUBLIC_DIR, "apple-touch-icon.png");
    assert.ok(fs.existsSync(appleIconPath), "public/apple-touch-icon.png must exist");
    assert.deepEqual(readPngDimensions(appleIconPath), { width: 180, height: 180 });

    const layout = fs.readFileSync(LAYOUT_PATH, "utf8");
    assert.match(layout, /https:\/\/web\.septena\.app/);
    assert.match(layout, /manifest:\s*"\/manifest\.webmanifest"/);
    assert.match(layout, /appleWebApp:\s*\{[\s\S]*capable:\s*true[\s\S]*title:\s*"Septena"/);
    assert.match(layout, /"apple-mobile-web-app-capable":\s*"yes"/);
    assert.match(layout, /\/apple-touch-icon\.png/);
  });

  it("pre-caches the manifest and icons in the service worker", () => {
    const sw = fs.readFileSync(path.join(PUBLIC_DIR, "sw.js"), "utf8");
    for (const asset of [
      "/manifest.webmanifest",
      "/icon.svg",
      "/icon-192.png",
      "/icon-512.png",
      "/icon-maskable-512.png",
      "/apple-touch-icon.png",
    ]) {
      assert.ok(sw.includes(`"${asset}"`), `sw.js SHELL_URLS must include ${asset}`);
    }
  });

  it("ships a full-resolution, filter-free vector icon.svg so Safari never pixelates it", () => {
    const svg = fs.readFileSync(path.join(PUBLIC_DIR, "icon.svg"), "utf8");
    assert.match(svg, /viewBox="0 0 1024 1024"/);
    assert.match(svg, /width="1024"\s+height="1024"/);
    assert.doesNotMatch(svg, /<filter\b|filter="url\(/);
  });
});
