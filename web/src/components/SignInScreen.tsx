"use client";

import { useCallback, useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import { ArrowLeft, RefreshCw, Smartphone } from "lucide-react";
import { ApiError, SeptenaApiClient } from "@/lib/api/client";
import { SIGN_IN, registryText } from "@/lib/generated/registries";
import type { DeviceStartResponse, SessionResponse } from "@/lib/types";
import { QrCode } from "./QrCode";
import { RegistryIcon } from "./RegistryIcon";

interface SignInScreenProps {
  api: SeptenaApiClient;
  language: string;
  onSignedIn: (session: SessionResponse) => void;
}

// The methods this client draws a flow for. Apple, Google and Microsoft on the
// web are later issues (#641): they stay hidden until their flow exists here.
const IMPLEMENTED = new Set<string>(["email", "device"]);

// Every wait on the network ends (AGENTS.md "No launch or load state without
// an exit"): a request that does not answer in time counts as a network error.
const METHODS_TIMEOUT_MS = 8000;
const REQUEST_TIMEOUT_MS = 15000;

type MethodId = (typeof SIGN_IN.methods)[number]["id"];

/** The methods to show, in the web order: registry flow, server switch, client support. */
function visibleMethods(serverMethods: readonly string[]): MethodId[] {
  const byId = new Map<string, (typeof SIGN_IN.methods)[number]>(SIGN_IN.methods.map((m) => [m.id, m]));
  return SIGN_IN.order.web.filter((id) => {
    const method = byId.get(id);
    const flow: string | undefined = method?.flows.web;
    return flow !== undefined && flow !== "none" && serverMethods.includes(id) && IMPLEMENTED.has(id);
  });
}

function methodTitle(id: MethodId, lang: string): string {
  const method = SIGN_IN.methods.find((m) => m.id === id);
  return registryText(method?.title ?? id, lang);
}

async function withTimeout<T>(ms: number, run: (signal: AbortSignal) => Promise<T>): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  try {
    return await run(controller.signal);
  } finally {
    clearTimeout(timer);
  }
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

/** Puts link elements where the registry sentence has `{name}` placeholders. */
function withLinks(text: string, links: Record<string, ReactNode>): ReactNode[] {
  return text.split(/(\{[a-zA-Z]+\})/).map((part, i) => {
    const name = part.match(/^\{([a-zA-Z]+)\}$/)?.[1];
    return <span key={i}>{name && name in links ? links[name] : part}</span>;
  });
}

export function SignInScreen({ api, language, onSignedIn }: SignInScreenProps) {
  // null: the server's method list has not answered yet.
  const [methods, setMethods] = useState<MethodId[] | null>(null);
  const [showDevice, setShowDevice] = useState(false);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      let server: string[];
      try {
        server = await withTimeout(METHODS_TIMEOUT_MS, (signal) => api.authMethods(signal));
      } catch {
        // Fail closed: an unknown server gets device approval only, as before.
        server = ["device"];
      }
      if (cancelled) return;
      const visible = visibleMethods(server);
      setMethods(visible.length > 0 ? visible : ["device"]);
    })();
    return () => {
      cancelled = true;
    };
  }, [api]);

  // The server said email sign-in is off: hide the form and fall back.
  const dropEmail = useCallback(() => {
    setMethods((prev) => {
      const next = (prev ?? []).filter((m) => m !== "email");
      return next.length > 0 ? next : ["device"];
    });
  }, []);

  const hasEmail = methods?.includes("email") ?? false;
  const hasDevice = methods?.includes("device") ?? false;
  const deviceActive = methods !== null && hasDevice && (!hasEmail || showDevice);

  const legalLinkClass = "underline underline-offset-2 hover:text-[var(--text-secondary)]";
  const links = {
    terms: (
      <a href={SIGN_IN.legal.terms} className={legalLinkClass}>
        {registryText(SIGN_IN.copy.termsLabel, language)}
      </a>
    ),
    privacy: (
      <a href={SIGN_IN.legal.privacy} className={legalLinkClass}>
        {registryText(SIGN_IN.copy.privacyLabel, language)}
      </a>
    ),
  };

  return (
    <main className="flex min-h-screen items-center justify-center bg-[var(--bg-sidebar)] p-4">
      <div className="w-full max-w-[420px] rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] p-7 shadow-sm">
        <div className="mb-5 flex items-center gap-3">
          <img src="/icon.svg" alt="" className="h-9 w-9 rounded-xl" />
          <div>
            <h1 className="text-lg font-semibold tracking-tight text-[var(--text-primary)]">
              {registryText(SIGN_IN.copy.heading, language)}
            </h1>
            <p className="text-xs text-[var(--text-muted)]">
              {registryText(SIGN_IN.copy.subheading, language)}
            </p>
          </div>
        </div>

        {methods === null && (
          <div className="flex h-40 items-center justify-center rounded-xl bg-[var(--bg-sidebar)] text-[var(--text-muted)]">
            <RefreshCw className="h-5 w-5 animate-spin" />
          </div>
        )}

        {methods !== null && !deviceActive && hasEmail && (
          <>
            <EmailSignIn api={api} language={language} onSignedIn={onSignedIn} onUnavailable={dropEmail} />
            {hasDevice && (
              <button
                type="button"
                onClick={() => setShowDevice(true)}
                className="mt-4 inline-flex w-full items-center justify-center gap-2 rounded-lg border border-[var(--border-subtle)] px-4 py-2.5 text-sm font-medium text-[var(--text-primary)] hover:bg-[var(--bg-sidebar)]"
              >
                <RegistryIcon token="auth.device" className="h-4 w-4" />
                {methodTitle("device", language)}
              </button>
            )}
          </>
        )}

        {deviceActive && (
          <>
            {hasEmail && (
              <button
                type="button"
                onClick={() => setShowDevice(false)}
                className="mb-4 inline-flex items-center gap-1.5 text-sm font-medium text-[var(--accent)] hover:opacity-90"
              >
                <ArrowLeft className="h-4 w-4" />
                {methodTitle("email", language)}
              </button>
            )}
            <DeviceApproval api={api} onSignedIn={onSignedIn} />
          </>
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

        <p className="mt-4 text-center text-xs leading-relaxed text-[var(--text-muted)]">
          {withLinks(registryText(SIGN_IN.copy.terms, language), links)}
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

// ── Email code (POST /v1/auth/email/start, /verify) ────────────────────────

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const DEFAULT_CODE_LENGTH = 6;

function EmailSignIn({
  api,
  language,
  onSignedIn,
  onUnavailable,
}: {
  api: SeptenaApiClient;
  language: string;
  onSignedIn: (session: SessionResponse) => void;
  onUnavailable: () => void;
}) {
  const t = (key: string, vars?: Record<string, string | number>) => registryText(key, language, vars);
  const [step, setStep] = useState<"address" | "code">("address");
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [codeLength, setCodeLength] = useState(DEFAULT_CODE_LENGTH);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // The code is used up (expired, too many tries): only a new code helps.
  const [codeDead, setCodeDead] = useState(false);
  const expiryTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const codeInput = useRef<HTMLInputElement | null>(null);

  const clearExpiry = () => {
    if (expiryTimer.current) clearTimeout(expiryTimer.current);
    expiryTimer.current = null;
  };
  useEffect(() => clearExpiry, []);

  const sendCode = async (address: string) => {
    const trimmed = address.trim();
    if (!EMAIL_PATTERN.test(trimmed)) {
      setError(t(SIGN_IN.errors.invalidEmail));
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const res = await withTimeout(REQUEST_TIMEOUT_MS, (signal) => api.startEmailSignIn(trimmed, signal));
      setEmail(trimmed);
      setCode("");
      setCodeDead(false);
      setCodeLength(res.codeLength ?? DEFAULT_CODE_LENGTH);
      setStep("code");
      // The code's own expiry is a wait too: end it with the expired line.
      clearExpiry();
      expiryTimer.current = setTimeout(() => {
        setCodeDead(true);
        setError(t(SIGN_IN.errors.codeExpired));
      }, Math.max(1, res.expiresInSeconds) * 1000);
      setTimeout(() => codeInput.current?.focus(), 0);
    } catch (err) {
      if (err instanceof ApiError && err.code === "email_signin_off") onUnavailable();
      else if (err instanceof ApiError && err.status === 400) setError(t(SIGN_IN.errors.invalidEmail));
      else if (err instanceof ApiError && err.status === 429) setError(t(SIGN_IN.errors.rateLimited));
      else setError(t(SIGN_IN.errors.network));
    } finally {
      setBusy(false);
    }
  };

  const verify = async () => {
    if (code.length !== codeLength || codeDead) return;
    setBusy(true);
    setError(null);
    try {
      const session = await withTimeout(REQUEST_TIMEOUT_MS, (signal) =>
        api.verifyEmailSignIn(email, code, signal),
      );
      clearExpiry();
      onSignedIn(session);
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        const left = attemptsLeft(err.rawBody);
        if (left > 0) {
          setError(t(SIGN_IN.errors.wrongCode.other, { count: left }));
          setCode("");
          codeInput.current?.focus();
        } else {
          clearExpiry();
          setCodeDead(true);
          setError(t(SIGN_IN.errors.tooManyTries));
        }
      } else if (err instanceof ApiError && err.status === 410) {
        clearExpiry();
        setCodeDead(true);
        setError(t(SIGN_IN.errors.codeExpired));
      } else if (err instanceof ApiError && err.status === 429) {
        clearExpiry();
        setCodeDead(true);
        setError(t(SIGN_IN.errors.tooManyTries));
      } else {
        setError(t(SIGN_IN.errors.network));
      }
    } finally {
      setBusy(false);
    }
  };

  const differentEmail = () => {
    clearExpiry();
    setStep("address");
    setCode("");
    setCodeDead(false);
    setError(null);
  };

  const onSubmit = (e: FormEvent) => {
    e.preventDefault();
    if (busy) return;
    if (step === "address") void sendCode(email);
    else void verify();
  };

  const inputClass =
    "w-full rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-canvas)] px-3 py-2.5 text-sm text-[var(--text-primary)] outline-none focus:border-[var(--accent)]";
  const primaryClass =
    "inline-flex w-full items-center justify-center gap-2 rounded-lg bg-[var(--accent)] px-4 py-2.5 text-sm font-medium text-white hover:opacity-90 disabled:opacity-50";
  const linkClass = "text-sm font-medium text-[var(--accent)] hover:opacity-90 disabled:opacity-50";

  return (
    <form onSubmit={onSubmit} noValidate>
      {step === "address" ? (
        <>
          <label htmlFor="signin-email" className="mb-1.5 block text-sm font-medium text-[var(--text-secondary)]">
            {t(SIGN_IN.email.emailLabel)}
          </label>
          <input
            id="signin-email"
            type="email"
            inputMode="email"
            autoComplete="email"
            autoCapitalize="none"
            spellCheck={false}
            autoFocus
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder={t(SIGN_IN.email.emailPlaceholder)}
            className={inputClass}
          />
        </>
      ) : (
        <>
          <p className="mb-3 text-sm text-[var(--text-secondary)]">{t(SIGN_IN.email.codeSent, { email })}</p>
          <label htmlFor="signin-code" className="mb-1.5 block text-sm font-medium text-[var(--text-secondary)]">
            {t(SIGN_IN.email.codeLabel)}
          </label>
          <input
            id="signin-code"
            ref={codeInput}
            type="text"
            inputMode="numeric"
            autoComplete="one-time-code"
            pattern="[0-9]*"
            maxLength={codeLength}
            value={code}
            disabled={codeDead}
            onChange={(e) => setCode(e.target.value.replace(/\D/g, "").slice(0, codeLength))}
            className={`${inputClass} font-mono-tabular text-center text-lg tracking-[0.3em]`}
          />
        </>
      )}

      {error && (
        <p role="alert" className="mt-2 text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      )}

      {step === "address" ? (
        <button type="submit" disabled={busy} className={`${primaryClass} mt-4`}>
          {busy ? <RefreshCw className="h-4 w-4 animate-spin" /> : <RegistryIcon token="auth.email" className="h-4 w-4" />}
          {t(SIGN_IN.email.sendCode)}
        </button>
      ) : (
        <>
          <button
            type="submit"
            disabled={busy || codeDead || code.length !== codeLength}
            className={`${primaryClass} mt-4`}
          >
            {busy && <RefreshCw className="h-4 w-4 animate-spin" />}
            {t(SIGN_IN.email.signIn)}
          </button>
          <div className="mt-3 flex items-center justify-between gap-3">
            <button type="button" disabled={busy} onClick={() => void sendCode(email)} className={linkClass}>
              {t(SIGN_IN.email.resend)}
            </button>
            <button type="button" disabled={busy} onClick={differentEmail} className={linkClass}>
              {t(SIGN_IN.email.differentEmail)}
            </button>
          </div>
        </>
      )}
    </form>
  );
}

function attemptsLeft(rawBody: string): number {
  try {
    const n = Number((JSON.parse(rawBody) as { attemptsLeft?: unknown }).attemptsLeft);
    return Number.isFinite(n) ? n : 0;
  } catch {
    return 0;
  }
}

// ── Device approval (POST /v1/auth/device/start, /poll) ────────────────────

function DeviceApproval({
  api,
  onSignedIn,
}: {
  api: SeptenaApiClient;
  onSignedIn: (session: SessionResponse) => void;
}) {
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
      const res = await withTimeout(REQUEST_TIMEOUT_MS, (signal) =>
        api.startDeviceSignIn(detectWebClientName(), signal),
      );
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

  // Poll POST /v1/auth/device/poll with sessionMode: "cookie". Leaving this
  // view (back to email) unmounts it, which stops the poll.
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
    <>
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
    </>
  );
}
