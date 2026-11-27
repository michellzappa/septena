import type { NextConfig } from "next";
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

const nextConfig: NextConfig = {
  env: { NEXT_PUBLIC_SEPTENA_VERSION: `${pkg.version} (${build})` },
  output: "export",
  images: {
    unoptimized: true,
  },
};

export default nextConfig;
