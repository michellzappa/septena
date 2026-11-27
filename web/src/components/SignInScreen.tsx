"use client";

import { useCallback, useEffect, useRef, useState, type CSSProperties, type FormEvent, type ReactNode } from "react";
import { ArrowLeft, RefreshCw, Smartphone } from "lucide-react";
import { ApiError, SeptenaApiClient } from "@/lib/api/client";
import { DESIGN_TOKENS, SIGN_IN, SURFACES_CATALOG, registryText } from "@/lib/generated/registries";
import { hexWithAlpha } from "@/lib/headerWash";
import type { AuthMethodEntry, DeviceStartResponse, SessionResponse } from "@/lib/types";
import { HeaderWash } from "./HeaderWash";
import { QrCode } from "./QrCode";
import { RegistryIcon } from "./RegistryIcon";

interface SignInScreenProps {
  api: SeptenaApiClient;
  language: string;
  isDark: boolean;
  dayISO: string;
  onSignedIn: (session: SessionResponse) => void;
}

type OidcProviderId = "apple" | "google" | "microsoft";
const OIDC_PROVIDERS = new Set<string>(["apple", "google", "microsoft"]);

// Every wait on the network ends (AGENTS.md "No launch or load state without
// an exit"): a request that does not answer in time counts as a network error.
const METHODS_TIMEOUT_MS = 8000;
const REQUEST_TIMEOUT_MS = 15000;

type MethodId = (typeof SIGN_IN.methods)[number]["id"];

/** The methods to show, in the web order: registry flow, server switch (and `web: true` for OIDC). */
function visibleMethods(serverEntries: readonly AuthMethodEntry[]): MethodId[] {
  const byId = new Map<string, (typeof SIGN_IN.methods)[number]>(SIGN_IN.methods.map((m) => [m.id, m]));
  const serverById = new Map(serverEntries.map((e) => [e.id, e]));
  return SIGN_IN.order.web.filter((id) => {
    const method = byId.get(id);
    const flow: string | undefined = method?.flows.web;
    if (!flow || flow === "none") return false;
    const entry = serverById.get(id);
    if (!entry) return false;
    if (OIDC_PROVIDERS.has(id)) return entry.web === true;
    return true;
  });
}

function providerName(id: string): string {
  const method = SIGN_IN.methods.find((m) => m.id === id);
  return method && "name" in method ? method.name : id;
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

interface PendingCollisionLink {
  email: string;
  provider: string;
  linkToken?: string;
}

export function SignInScreen({ api, language, isDark, dayISO, onSignedIn }: SignInScreenProps) {
  // null: the server's method list has not answered yet.
  const [methods, setMethods] = useState<MethodId[] | null>(null);
  const [showDevice, setShowDevice] = useState(false);
  const [oidcBusy, setOidcBusy] = useState(false);
  const [oidcError, setOidcError] = useState<string | null>(null);
  const [collision, setCollision] = useState<PendingCollisionLink | null>(null);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      let server: AuthMethodEntry[];
      try {
        server = await withTimeout(METHODS_TIMEOUT_MS, (signal) => api.authMethodEntries(signal));
      } catch {
        // Fail closed: an unknown server gets device approval only, as before.
        server = [{ id: "device" }];
      }
      if (cancelled) return;
      const visible = visibleMethods(server);
      setMethods(visible.length > 0 ? visible : ["device"]);
    })();
    return () => {
      cancelled = true;
    };
  }, [api]);

  // Redeem `?oidc_code=` (or show `?oidc_error=`) when returning from an OIDC provider.
  useEffect(() => {
    if (typeof window === "undefined") return;
    const params = new URLSearchParams(window.location.search);
    if (params.get("oidc_link") === "1") return;
    const code = params.get("oidc_code");
    const err = params.get("oidc_error");
    if (!code && !err) return;
    window.history.replaceState({}, "", window.location.pathname);
    if (err) {
      if (err !== "cancelled" && err !== "access_denied") {
        setOidcError(registryText(SIGN_IN.errors.network, language));
      }
      return;
    }
    if (!code) return;
    let cancelled = false;
    setOidcBusy(true);
    setOidcError(null);
    void (async () => {
      try {
        const res = await withTimeout(REQUEST_TIMEOUT_MS, (signal) => api.redeemOidcSignIn(code, signal));
        if (cancelled) return;
        if (res.status === "signed_in") {
          onSignedIn(res.session);
        } else {
          setCollision({ email: res.email, provider: res.provider, linkToken: res.linkToken });
        }
      } catch {
        if (!cancelled) setOidcError(registryText(SIGN_IN.errors.network, language));
      } finally {
        if (!cancelled) setOidcBusy(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [api, language, onSignedIn]);

  // The server said email sign-in is off: hide the form and fall back.
  const dropEmail = useCallback(() => {
    setMethods((prev) => {
      const next = (prev ?? []).filter((m) => m !== "email");
      return next.length > 0 ? next : ["device"];
    });
  }, []);

  const oidcMethods = (methods ?? []).filter((m): m is OidcProviderId => OIDC_PROVIDERS.has(m));
  const hasEmail = methods?.includes("email") ?? false;
  const hasDevice = methods?.includes("device") ?? false;
  const hasPrimary = oidcMethods.length > 0 || hasEmail;
  const deviceActive = methods !== null && hasDevice && (!hasPrimary || showDevice);

  const startOidc = (provider: OidcProviderId) => {
    if (typeof window === "undefined") return;
    const returnTo = `${window.location.origin}${window.location.pathname}`;
    window.location.href = api.oidcStartUrl(provider, returnTo);
  };

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

  // Sign-in is a brand surface (before any user accent is loaded): use Persimmon
  // and the Topography texture from the shared design token registry.
  const brandFruit =
    DESIGN_TOKENS.fruitAccents.find((f) => f.id === "persimmon") ??
    DESIGN_TOKENS.fruitAccents[0];
  const brandAccent = isDark ? brandFruit.dark : brandFruit.light;
  const brandCheck = isDark ? brandFruit.checkDark : brandFruit.checkLight;
  const brandSelected = hexWithAlpha(
    brandAccent,
    isDark
      ? DESIGN_TOKENS.selection.emphasizedAlphaDark
      : DESIGN_TOKENS.selection.emphasizedAlphaLight,
  );
  const brandStyle = {
    ["--accent" as string]: brandAccent,
    ["--accent-check" as string]: brandCheck,
    ["--bg-selected" as string]: brandSelected,
    accentColor: brandAccent,
  } as CSSProperties;

  return (
    <main
      className="relative flex min-h-screen items-center justify-center overflow-hidden bg-[var(--bg-canvas)] p-4"
      style={brandStyle}
    >
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 top-0 z-0 h-96"
        style={{
          backgroundImage: `linear-gradient(to bottom, ${hexWithAlpha(brandAccent, isDark ? 0.14 : 0.09)}, transparent)`,
        }}
      />
      <HeaderWash
        style="topography"
        isDark={isDark}
        accentHex={brandAccent}
        intensity={65}
        motion="still"
        dayISO={dayISO}
        fullBleed
      />
      <div className="relative z-10 w-full max-w-[420px] rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)]/95 p-7 shadow-lg backdrop-blur-sm">
        <div className="mb-5 flex items-center gap-3">
          <img
            src="/icon.svg"
            alt=""
            width={40}
            height={40}
            draggable={false}
            className="h-10 w-10 shrink-0 select-none"
          />
          <div>
            <h1 className="text-lg font-semibold tracking-tight text-[var(--text-primary)]">
              {registryText(SIGN_IN.copy.heading, language)}
            </h1>
            <p className="text-xs text-[var(--text-muted)]">
              {registryText(SIGN_IN.copy.subheading, language)}
            </p>
          </div>
        </div>

        {(methods === null || oidcBusy) && (
          <div className="flex h-40 items-center justify-center rounded-xl bg-[var(--bg-sidebar)] text-[var(--text-muted)]">
            <RefreshCw className="h-5 w-5 animate-spin" />
          </div>
        )}

        {!oidcBusy && collision && (
          <CollisionLinkForm
            api={api}
            language={language}
            collision={collision}
            onSignedIn={onSignedIn}
            onCancel={() => setCollision(null)}
          />
        )}

        {!oidcBusy && !collision && methods !== null && !deviceActive && hasPrimary && (
          <>
            {oidcError && (
              <p role="alert" className="mb-3 text-sm text-red-600 dark:text-red-400">
                {oidcError}
              </p>
            )}
            {oidcMethods.length > 0 && (
              <div className="mb-4 space-y-2">
                {oidcMethods.map((id) => {
                  const icon = SIGN_IN.methods.find((m) => m.id === id)?.icon ?? `auth.${id}`;
                  return (
                    <button
                      key={id}
                      type="button"
                      onClick={() => startOidc(id)}
                      className="inline-flex w-full items-center justify-center gap-2 rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-canvas)] px-4 py-2.5 text-sm font-medium text-[var(--text-primary)] hover:bg-[var(--bg-sidebar)]"
                    >
                      <RegistryIcon token={icon} className="h-4 w-4" />
                      {methodTitle(id, language)}
                    </button>
                  );
                })}
              </div>
            )}
            {hasEmail && (
              <EmailSignIn api={api} language={language} onSignedIn={onSignedIn} onUnavailable={dropEmail} />
            )}
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

        {!oidcBusy && !collision && deviceActive && (
          <>
            {hasPrimary && (
              <button
                type="button"
                onClick={() => setShowDevice(false)}
                className="mb-4 inline-flex items-center gap-1.5 text-sm font-medium text-[var(--accent)] hover:opacity-90"
              >
                <ArrowLeft className="h-4 w-4" />
                {registryText(SIGN_IN.copy.heading, language)}
              </button>
            )}
            <DeviceApproval api={api} language={language} onSignedIn={onSignedIn} />
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

// ── Existing-account collision link (ADR 0047 decision 5) ─────────────────

function CollisionLinkForm({
  api,
  language,
  collision,
  onSignedIn,
  onCancel,
}: {
  api: SeptenaApiClient;
  language: string;
  collision: PendingCollisionLink;
  onSignedIn: (session: SessionResponse) => void;
  onCancel: () => void;
}) {
  const t = (key: string, vars?: Record<string, string | number>) => registryText(key, language, vars);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const name = providerName(collision.provider);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!collision.linkToken || code.length !== DEFAULT_CODE_LENGTH || busy) return;
    setBusy(true);
    setError(null);
    try {
      const session = await withTimeout(REQUEST_TIMEOUT_MS, (signal) =>
        api.completeCollisionLink(collision.linkToken!, code, signal),
      );
      onSignedIn(session);
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        const left = attemptsLeft(err.rawBody);
        setError(left > 0 ? t(SIGN_IN.errors.wrongCode.other, { count: left }) : t(SIGN_IN.errors.tooManyTries));
        setCode("");
      } else if (err instanceof ApiError && err.status === 410) {
        setError(t(SIGN_IN.errors.codeExpired));
      } else if (err instanceof ApiError && err.status === 429) {
        setError(t(SIGN_IN.errors.tooManyTries));
      } else {
        setError(t(SIGN_IN.errors.network));
      }
    } finally {
      setBusy(false);
    }
  };

  return (
    <form onSubmit={(e) => void submit(e)} className="space-y-3" noValidate>
      <h2 className="text-base font-semibold text-[var(--text-primary)]">{t(SIGN_IN.existingAccount.title)}</h2>
      <p className="text-sm text-[var(--text-secondary)]">
        {t(SIGN_IN.existingAccount.detail, { email: collision.email, provider: name })}
      </p>
      {collision.linkToken ? (
        <>
          <label htmlFor="collision-code" className="block text-sm font-medium text-[var(--text-secondary)]">
            {t(SIGN_IN.email.codeLabel)}
          </label>
          <input
            id="collision-code"
            type="text"
            inputMode="numeric"
            autoComplete="one-time-code"
            pattern="[0-9]*"
            maxLength={DEFAULT_CODE_LENGTH}
            value={code}
            onChange={(e) => setCode(e.target.value.replace(/\D/g, "").slice(0, DEFAULT_CODE_LENGTH))}
            className="font-mono-tabular w-full rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-canvas)] px-3 py-2.5 text-center text-lg tracking-[0.3em] text-[var(--text-primary)] outline-none focus:border-[var(--accent)] focus:ring-2 focus:ring-[var(--accent)]/20"
          />
          {error && <p role="alert" className="text-sm text-red-600 dark:text-red-400">{error}</p>}
          <button
            type="submit"
            disabled={busy || code.length !== DEFAULT_CODE_LENGTH}
            className="inline-flex w-full items-center justify-center gap-2 rounded-lg bg-[var(--accent)] px-4 py-2.5 text-sm font-medium text-white hover:opacity-90 disabled:opacity-50"
          >
            {busy && <RefreshCw className="h-4 w-4 animate-spin" />}
            {t(SIGN_IN.email.signIn)}
          </button>
        </>
      ) : (
        <p className="text-sm text-[var(--text-muted)]">
          {t(SIGN_IN.existingAccount.manualDetail, { email: collision.email, provider: name })}
        </p>
      )}
      <button
        type="button"
        onClick={onCancel}
        className="w-full text-center text-sm font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
      >
        {t(SIGN_IN.manage.cancel)}
      </button>
    </form>
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
    "w-full rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-canvas)] px-3 py-2.5 text-sm text-[var(--text-primary)] outline-none focus:border-[var(--accent)] focus:ring-2 focus:ring-[var(--accent)]/20";
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

/** One line of surfaces.json `deviceSignIn.copy`, the same words the other apps show. */
function deviceSignInCopy(id: string, lang: string): string {
  const label = SURFACES_CATALOG.deviceSignIn.copy.find((c) => c.id === id)?.label ?? id;
  return registryText(label, lang);
}

function DeviceApproval({
  api,
  language,
  onSignedIn,
}: {
  api: SeptenaApiClient;
  language: string;
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
        {deviceSignInCopy("approve", language)}
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
            {status === "expired" && deviceSignInCopy("expired", language)}
            {status === "error" && (errorMessage ?? "Could not start sign-in.")}
          </p>
          <button
            type="button"
            onClick={() => void startPairing()}
            className="inline-flex items-center gap-2 rounded-lg bg-[var(--accent)] px-4 py-2 text-sm font-medium text-white hover:opacity-90"
          >
            <RefreshCw className="h-4 w-4" />
            {deviceSignInCopy("retry", language)}
          </button>
        </div>
      )}
    </>
  );
}
