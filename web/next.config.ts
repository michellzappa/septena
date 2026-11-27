import type { NextConfig } from "next";
import { PHASE_DEVELOPMENT_SERVER } from "next/constants";
import { execSync } from "node:child_process";
import pkg from "./package.json";

// X-Septena-Version: "<version> (<build>)". The build is the git commit
// count, as on the Apple and Android apps; 0 when git is not there.
const build = (() => {
  try {
    return execSync("git rev-list --count HEAD", { stdio: ["ignore", "pipe", "ignore"] }).toString().trim();
  } catch {
    return "0";
  }
})();

export default function nextConfig(phase: string): NextConfig {
  const isDev = phase === PHASE_DEVELOPMENT_SERVER;
  return {
    env: { NEXT_PUBLIC_SEPTENA_VERSION: `${pkg.version} (${build})` },
    ...(isDev
      ? {
          // Mirror Cloudflare Workers' `not_found_handling: "single-page-application"`
          // in `next dev` so refreshing any SPA URL (/today, /project/:id, …) works locally.
          async rewrites() {
            return [
              {
                source: "/:path((?!_next/|wasm/|.*\\..*).*)",
                destination: "/",
              },
            ];
          },
        }
      : { output: "export" }),
    images: {
      unoptimized: true,
    },
  };
}
