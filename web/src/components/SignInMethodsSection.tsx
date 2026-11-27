"use client";

import { useCallback, useEffect, useState, type FormEvent } from "react";
import { Plus, RefreshCw, Shield, Trash2 } from "lucide-react";
import { ApiError, SeptenaApiClient } from "@/lib/api/client";
import { SIGN_IN, registryText } from "@/lib/generated/registries";
import type { AuthMethodEntry, LinkedIdentitiesResponse } from "@/lib/types";
import { RegistryIcon } from "./RegistryIcon";

interface SignInMethodsSectionProps {
  api: SeptenaApiClient;
  language: string;
}

const OIDC_PROVIDERS = ["apple", "google", "microsoft"] as const;
type OidcProvider = (typeof OIDC_PROVIDERS)[number];

export function SignInMethodsSection({ api, language }: SignInMethodsSectionProps) {
  const t = (key: string, vars?: Record<string, string | number>) => registryText(key, language, vars);
  const [data, setData] = useState<LinkedIdentitiesResponse | null>(null);
  const [serverMethods, setServerMethods] = useState<AuthMethodEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);

  // Inline "Add email" 2-step form
  const [addingEmail, setAddingEmail] = useState(false);
  const [emailInput, setEmailInput] = useState("");
  const [emailSentTo, setEmailSentTo] = useState<string | null>(null);
  const [codeInput, setCodeInput] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [identities, methods] = await Promise.all([
        api.listIdentities(),
        api.authMethodEntries().catch(() => [] as AuthMethodEntry[]),
      ]);
      setData(identities);
      setServerMethods(methods);
    } catch {
      setError(t(SIGN_IN.manage.loadFailed));
    } finally {
      setLoading(false);
    }
  }, [api, language]);

  useEffect(() => {
    void load();
  }, [load]);

  const handleRemove = async (id: string) => {
    if (busy) return;
    setBusy(true);
    setError(null);
    setStatus(null);
    try {
      const next = await api.unlinkIdentity(id);
      setData(next);
      setStatus(t(SIGN_IN.manage.removed));
    } catch (err) {
      if (err instanceof ApiError && err.code === "last_method") {
        setError(t(SIGN_IN.manage.lastMethod));
      } else {
        setError(t(SIGN_IN.manage.removeFailed));
      }
    } finally {
      setBusy(false);
    }
  };

  const handleStartEmail = async (e: FormEvent) => {
    e.preventDefault();
    const trimmed = emailInput.trim();
    if (!trimmed || busy) return;
    setBusy(true);
    setError(null);
    setStatus(null);
    try {
      await api.startLinkEmail(trimmed);
      setEmailSentTo(trimmed);
      setCodeInput("");
    } catch (err) {
      if (err instanceof ApiError && err.status === 400) setError(t(SIGN_IN.errors.invalidEmail));
      else if (err instanceof ApiError && err.status === 429) setError(t(SIGN_IN.errors.rateLimited));
      else setError(t(SIGN_IN.errors.network));
    } finally {
      setBusy(false);
    }
  };

  const handleVerifyEmail = async (e: FormEvent) => {
    e.preventDefault();
    if (!emailSentTo || codeInput.length !== 6 || busy) return;
    setBusy(true);
    setError(null);
    setStatus(null);
    try {
      const next = await api.verifyLinkEmail(emailSentTo, codeInput);
      setData(next);
      setAddingEmail(false);
      setEmailInput("");
      setEmailSentTo(null);
      setCodeInput("");
      setStatus(t(SIGN_IN.manage.added));
    } catch (err) {
      if (err instanceof ApiError && err.code === "already_linked") {
        setError(t(SIGN_IN.manage.alreadyLinked));
      } else if (err instanceof ApiError && err.status === 401) {
        setError(t(SIGN_IN.errors.wrongCode.other, { count: 1 }));
        setCodeInput("");
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

  const handleAddOidc = async (provider: OidcProvider) => {
    if (busy || typeof window === "undefined") return;
    setBusy(true);
    setError(null);
    try {
      const returnTo = `${window.location.origin}${window.location.pathname}?oidc_link=1`;
      const url = await api.startLinkOidc(provider, returnTo);
      window.location.href = url;
    } catch {
      setError(t(SIGN_IN.errors.network));
      setBusy(false);
    }
  };

  const linkedProviders = new Set((data?.identities ?? []).map((i) => i.provider));
  const emailAvailable = serverMethods.some((m) => m.id === "email");
  const addableOidc = OIDC_PROVIDERS.filter(
    (p) => !linkedProviders.has(p) && serverMethods.some((m) => m.id === p && m.web === true),
  );

  return (
    <section className="rounded-xl border border-[var(--border-subtle)] p-4">
      <h3 className="mb-1.5 flex items-center gap-1.5 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
        <Shield className="h-3.5 w-3.5" />
        {t(SIGN_IN.manage.heading)}
      </h3>
      <p className="mb-3 text-[11px] text-[var(--text-muted)]">
        {t(SIGN_IN.manage.footer)}
      </p>

      {loading ? (
        <div className="flex items-center gap-2 py-2 text-xs text-[var(--text-muted)]">
          <RefreshCw className="h-3.5 w-3.5 animate-spin" />
        </div>
      ) : (
        <div className="space-y-2">
          {(data?.identities ?? []).map((item) => {
            const icon = SIGN_IN.methods.find((m) => m.id === item.provider)?.icon ?? "auth.email";
            return (
              <div
                key={item.id}
                className="flex items-center justify-between rounded-lg border border-[var(--border-subtle)] px-3 py-2 text-xs"
              >
                <div className="flex min-w-0 items-center gap-2">
                  <RegistryIcon token={icon} className="h-3.5 w-3.5 shrink-0 text-[var(--text-secondary)]" />
                  <span className="truncate font-medium text-[var(--text-primary)]">{item.label}</span>
                </div>
                {data?.canRemove && (
                  <button
                    type="button"
                    disabled={busy}
                    onClick={() => void handleRemove(item.id)}
                    className="inline-flex shrink-0 items-center gap-1 rounded-md px-2 py-1 text-[11px] text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-red-600 disabled:opacity-50"
                  >
                    <Trash2 className="h-3 w-3" />
                    {t(SIGN_IN.manage.remove)}
                  </button>
                )}
              </div>
            );
          })}

          {addingEmail && (
            <form
              onSubmit={(e) => void (emailSentTo ? handleVerifyEmail(e) : handleStartEmail(e))}
              className="space-y-2 rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-sidebar)] p-3"
            >
              {!emailSentTo ? (
                <>
                  <input
                    type="email"
                    value={emailInput}
                    onChange={(e) => setEmailInput(e.target.value)}
                    placeholder={t(SIGN_IN.email.emailPlaceholder)}
                    className="w-full rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-canvas)] px-2.5 py-1.5 text-xs text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                  />
                  <div className="flex items-center gap-2">
                    <button
                      type="submit"
                      disabled={busy || !emailInput.trim()}
                      className="rounded-lg bg-[var(--accent)] px-3 py-1.5 text-xs font-medium text-white hover:opacity-90 disabled:opacity-50"
                    >
                      {t(SIGN_IN.email.sendCode)}
                    </button>
                    <button
                      type="button"
                      onClick={() => { setAddingEmail(false); setError(null); }}
                      className="rounded-lg px-2.5 py-1.5 text-xs text-[var(--text-muted)] hover:bg-[var(--bg-hover)]"
                    >
                      {t(SIGN_IN.manage.cancel)}
                    </button>
                  </div>
                </>
              ) : (
                <>
                  <p className="text-[11px] text-[var(--text-secondary)]">
                    {t(SIGN_IN.email.codeSent, { email: emailSentTo })}
                  </p>
                  <input
                    type="text"
                    inputMode="numeric"
                    maxLength={6}
                    value={codeInput}
                    onChange={(e) => setCodeInput(e.target.value.replace(/\D/g, "").slice(0, 6))}
                    placeholder="123456"
                    className="font-mono-tabular w-full rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-canvas)] px-2.5 py-1.5 text-center text-sm tracking-[0.25em] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                  />
                  <div className="flex items-center gap-2">
                    <button
                      type="submit"
                      disabled={busy || codeInput.length !== 6}
                      className="rounded-lg bg-[var(--accent)] px-3 py-1.5 text-xs font-medium text-white hover:opacity-90 disabled:opacity-50"
                    >
                      {t(SIGN_IN.manage.addEmail)}
                    </button>
                    <button
                      type="button"
                      onClick={() => { setEmailSentTo(null); setCodeInput(""); setError(null); }}
                      className="rounded-lg px-2.5 py-1.5 text-xs text-[var(--text-muted)] hover:bg-[var(--bg-hover)]"
                    >
                      {t(SIGN_IN.manage.cancel)}
                    </button>
                  </div>
                </>
              )}
            </form>
          )}

          {(emailAvailable || addableOidc.length > 0) && !addingEmail && (
            <div className="flex flex-wrap gap-2 pt-1">
              {addableOidc.map((provider) => {
                const method = SIGN_IN.methods.find((m) => m.id === provider);
                const name = method && "name" in method ? method.name : provider;
                return (
                  <button
                    key={provider}
                    type="button"
                    disabled={busy}
                    onClick={() => void handleAddOidc(provider)}
                    className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-2.5 py-1.5 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)] disabled:opacity-50"
                  >
                    <Plus className="h-3 w-3" />
                    {t(SIGN_IN.manage.addProvider, { provider: name })}
                  </button>
                );
              })}
              {emailAvailable && (
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => { setAddingEmail(true); setError(null); setStatus(null); }}
                  className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-2.5 py-1.5 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)] disabled:opacity-50"
                >
                  <Plus className="h-3 w-3" />
                  {t(SIGN_IN.manage.addEmail)}
                </button>
              )}
            </div>
          )}

          {error && <p className="text-xs text-[var(--overdue-red)]">{error}</p>}
          {status && <p className="text-xs text-[var(--text-secondary)]">{status}</p>}
        </div>
      )}
    </section>
  );
}
