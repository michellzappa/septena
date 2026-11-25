"use client";

import { useEffect, useRef } from "react";
import {
  drawHeaderWash,
  hexToRgbTriple,
  resolvedWashSeed,
  type HeaderTextureStyle,
} from "@/lib/headerWash";

interface HeaderWashProps {
  style: HeaderTextureStyle;
  isDark: boolean;
  accentHex: string;
  intensity: number;
  motion: "still" | "slowDrift";
  dayISO: string;
  projectId?: string | null;
  fadeHeight?: number;
}

export function HeaderWash({
  style,
  isDark,
  accentHex,
  intensity,
  motion,
  dayISO,
  projectId,
  fadeHeight = 260,
}: HeaderWashProps) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const phaseRef = useRef(0);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || style === "none") return;

    const accent = hexToRgbTriple(accentHex);
    const seed = resolvedWashSeed(dayISO, projectId);
    const reduceMotion =
      typeof window !== "undefined" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const increaseContrast =
      typeof window !== "undefined" &&
      window.matchMedia("(prefers-contrast: more)").matches;
    const shouldAnimate = motion === "slowDrift" && !reduceMotion;

    const render = (phase: number) => {
      const rect = canvas.getBoundingClientRect();
      if (rect.width < 2 || rect.height < 2) return;
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      const pw = Math.round(rect.width * dpr);
      const ph = Math.round(rect.height * dpr);
      if (canvas.width !== pw || canvas.height !== ph) {
        canvas.width = pw;
        canvas.height = ph;
      }
      const ctx = canvas.getContext("2d");
      if (!ctx) return;
      ctx.save();
      ctx.scale(dpr, dpr);
      drawHeaderWash(ctx, rect.width, rect.height, {
        style,
        isDark,
        accent,
        intensity,
        seed,
        phase,
        fadeHeight,
        mini: false,
        increaseContrast,
      });
      ctx.restore();
    };

    render(phaseRef.current);

    const ro = new ResizeObserver(() => render(phaseRef.current));
    ro.observe(canvas);

    let rafId = 0;
    let lastTs = performance.now();
    let lastFrame = lastTs;

    const tick = (now: number) => {
      if (document.visibilityState === "visible") {
        // 15 fps cap matching HeaderWashView.swift so scrolling stays silky.
        if (now - lastFrame >= 66) {
          phaseRef.current += (now - lastTs) / 1000;
          lastFrame = now;
          render(phaseRef.current);
        }
      }
      lastTs = now;
      rafId = requestAnimationFrame(tick);
    };

    if (shouldAnimate) {
      rafId = requestAnimationFrame(tick);
    }

    return () => {
      ro.disconnect();
      if (rafId) cancelAnimationFrame(rafId);
    };
  }, [accentHex, dayISO, fadeHeight, intensity, isDark, motion, projectId, style]);

  if (style === "none") return null;

  return (
    <canvas
      ref={canvasRef}
      aria-hidden="true"
      className="pointer-events-none absolute inset-x-0 top-0 z-0 w-full select-none"
      style={{ height: `${fadeHeight}px` }}
    />
  );
}

interface HeaderWashPreviewProps {
  style: HeaderTextureStyle;
  isDark: boolean;
  accentHex: string;
  intensity: number;
  dayISO: string;
}

export function HeaderWashPreview({
  style,
  isDark,
  accentHex,
  intensity,
  dayISO,
}: HeaderWashPreviewProps) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || style === "none") return;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = 120;
    const h = 44;
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.save();
    ctx.scale(dpr, dpr);
    drawHeaderWash(ctx, w, h, {
      style,
      isDark,
      accent: hexToRgbTriple(accentHex),
      intensity: Math.max(55, intensity),
      seed: resolvedWashSeed(dayISO),
      phase: 0,
      fadeHeight: h,
      mini: true,
      increaseContrast: false,
    });
    ctx.restore();
  }, [accentHex, dayISO, intensity, isDark, style]);

  if (style === "none") return null;

  return (
    <canvas
      ref={canvasRef}
      aria-hidden="true"
      className="pointer-events-none h-11 w-full rounded-md"
    />
  );
}
