"use client";

import { useMemo } from "react";

interface QrCodeProps {
  size: number;
  modules: string;
  label?: string;
}

// Draws the QR module matrix returned by POST /v1/auth/device/start with a
// 4-module white quiet zone. Always dark-on-white (even in dark mode) so
// phone cameras scan reliably (matches backend/src/shadow/pairQr.ts).
export function QrCode({ size, modules, label = "Sign-in QR code" }: QrCodeProps) {
  const { side, path } = useMemo(() => {
    const quiet = 4;
    const total = size + quiet * 2;
    let d = "";
    for (let r = 0; r < size; r++) {
      for (let c = 0; c < size; c++) {
        if (modules[r * size + c] === "1") {
          d += `M${c + quiet} ${r + quiet}h1v1h-1z`;
        }
      }
    }
    return { side: total, path: d };
  }, [size, modules]);

  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox={`0 0 ${side} ${side}`}
      shapeRendering="crispEdges"
      role="img"
      aria-label={label}
      className="block h-full w-full"
    >
      <rect width={side} height={side} fill="#ffffff" />
      <path d={path} fill="#000000" />
    </svg>
  );
}
