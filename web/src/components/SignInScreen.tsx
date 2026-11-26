"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { RefreshCw, Smartphone } from "lucide-react";
import { SeptenaApiClient } from "@/lib/api/client";
import type { DeviceStartResponse, SessionResponse } from "@/lib/types";
import { QrCode } from "./QrCode";

interface SignInScreenProps {
  api: SeptenaApiClient;
  onSignedIn: (session: SessionResponse) => void;
}

function detectWebClientName(): string {
  if (typeof navigator === "undefined") return "Septena Web";
  const ua = navigator.userAgent;
  if (ua.includes("Firefox")) return "Web Firefox";
  if (ua.includes("Edg/")) return "Web Edge";
  if (ua.includes("Chrome") && !ua.includes("Edg/")) return "Web Chrome";
  if (ua.includes("Safari") && !ua.includes("Chrome")) return "Web Safari";
  return "Septena Web";
}

function formatCode(code: string): string {
  return code.length === 8 ? `${code.slice(0, 4)}-${code.slice(4)}` : code;
}

export function SignInScreen({ api, onSignedIn }: SignInScreenProps) {
  const [pairing, setPairing] = useState<DeviceStartResponse | null>(null);
  const [status, setStatus] = useState<"starting" | "waiting" | "denied" | "expired" | "error">("starting");
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [secondsLeft, setSecondsLeft] = useState<number>(0);
  const activeSecretRef = useRef<string | null>(null);

  const startPairing = useCallback(async () => {
    setStatus("starting");
    setErrorMessage(null);
    setPairing(null);
    activeSecretRef.current = null;
    try {
      const res = await api.startDeviceSignIn(detectWebClientName());
      activeSecretRef.current = res.pollSecret;
      setPairing(res);
      setSecondsLeft(Math.round(res.expiresIn));
      setStatus("waiting");
    } catch (err) {
      setStatus("error");
      setErrorMessage(err instanceof Error ? err.message : "Could not reach api.septena.app");
    }
  }, [api]);

  useEffect(() => {
    void startPairing();
  }, [startPairing]);

  // Countdown timer
  useEffect(() => {
    if (status !== "waiting") return;
    const t = setInterval(() => {
      setSecondsLeft((prev) => {
        if (prev <= 1) {
          setStatus("expired");
          return 0;
        }
        return prev - 1;
      });
    }, 1000);
    return () => clearInterval(t);
  }, [status]);

  // Poll POST /v1/auth/device/poll with sessionMode: "cookie"
  useEffect(() => {
    if (status !== "waiting" || !pairing) return;
    let cancelled = false;
    const intervalMs = Math.max(2000, pairing.interval * 1000);

    const poll = async () => {
      if (cancelled || activeSecretRef.current !== pairing.pollSecret) return;
      try {
        const res = await api.pollDeviceSignIn(pairing.code, pairing.pollSecret);
        if (cancelled || activeSecretRef.current !== pairing.pollSecret) return;
        if (res.status === "approved") {
          onSignedIn(res.session);
          return;
        }
        if (res.status === "denied") {
          setStatus("denied");
          return;
        }
        if (res.status === "expired") {
          setStatus("expired");
          return;
        }
      } catch (err) {
        if (cancelled) return;
        setStatus("error");
        setErrorMessage(err instanceof Error ? err.message : "Approval check failed");
      }
    };

    const id = setInterval(() => void poll(), intervalMs);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [api, onSignedIn, pairing, status]);

  const mins = Math.floor(secondsLeft / 60);
  const secs = String(secondsLeft % 60).padStart(2, "0");

  return (
    <main className="flex min-h-screen items-center justify-center bg-[var(--bg-sidebar)] p-4">
      <div className="w-full max-w-[420px] rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] p-7 shadow-sm">
        <div className="mb-5 flex items-center gap-3">
          <img src="/icon.svg" alt="" className="h-9 w-9 rounded-xl" />
          <div>
            <h1 className="text-lg font-semibold tracking-tight text-[var(--text-primary)]">
              Septena Web
            </h1>
            <p className="text-xs text-[var(--text-muted)]">web.septena.app · spike</p>
          </div>
        </div>

        <p className="mb-5 text-sm leading-relaxed text-[var(--text-secondary)]">
          Sign in by approving this browser from a signed-in Septena app. Open{" "}
          <span className="font-medium text-[var(--text-primary)]">
            Settings → Account → Approve a device
          </span>{" "}
          on your iPhone, iPad, Mac, or Android.
        </p>

        {status === "starting" && (
          <div className="flex h-64 flex-col items-center justify-center gap-2 rounded-xl bg-[var(--bg-sidebar)] text-sm text-[var(--text-muted)]">
            <RefreshCw className="h-5 w-5 animate-spin" />
            <span>Generating sign-in code…</span>
          </div>
        )}

        {status === "waiting" && pairing && (
          <div>
            <div className="mx-auto mb-4 aspect-square w-48 overflow-hidden rounded-xl border border-[var(--border-subtle)] bg-white p-1">
              <QrCode size={pairing.qr.size} modules={pairing.qr.modules} />
            </div>

            <div className="font-mono-tabular mb-3 rounded-xl bg-[var(--bg-sidebar)] py-3 text-center text-2xl font-semibold tracking-[0.14em] text-[var(--text-primary)] select-all">
              {formatCode(pairing.code)}
            </div>

            <div className="flex items-center justify-between text-xs text-[var(--text-muted)]">
              <span className="inline-flex items-center gap-1.5">
                <Smartphone className="h-3.5 w-3.5" />
                Waiting for approval…
              </span>
              <span className="font-mono-tabular">
                Expires in {mins}:{secs}
              </span>
            </div>
          </div>
        )}

        {(status === "denied" || status === "expired" || status === "error") && (
          <div className="rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-sidebar)] p-5 text-center">
            <p className="mb-3 text-sm text-[var(--text-secondary)]">
              {status === "denied" && "Sign-in was denied from the other device."}
              {status === "expired" && "That code expired."}
              {status === "error" && (errorMessage ?? "Could not start sign-in.")}
            </p>
            <button
              type="button"
              onClick={() => void startPairing()}
              className="inline-flex items-center gap-2 rounded-lg bg-[var(--accent)] px-4 py-2 text-sm font-medium text-white hover:opacity-90"
            >
              <RefreshCw className="h-4 w-4" />
              Get a new code
            </button>
          </div>
        )}

        {/* A visitor with no Septena app has nothing to approve this browser
            from: point them at the apps. Same tab, like every site link. */}
        <p className="mt-5 text-center text-sm text-[var(--text-secondary)]">
          New to Septena?{" "}
          <a
            href="https://septena.app/download"
            className="font-medium text-[var(--accent)] underline-offset-4 hover:underline"
          >
            Get the app
          </a>
        </p>

        <p className="mt-6 border-t border-[var(--border-subtle)] pt-4 text-xs leading-relaxed text-[var(--text-muted)]">
          Task data syncs directly between this browser and{" "}
          <span className="font-mono-tabular">api.septena.app</span>, stored locally in
          IndexedDB so new tasks queue offline and push on reconnect.
        </p>
      </div>
    </main>
  );
}
