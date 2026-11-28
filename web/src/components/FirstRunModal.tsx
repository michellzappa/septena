"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import {
  Bot,
  Check,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  Copy,
  MessagesSquare,
  MonitorSmartphone,
  StickyNote,
  X,
} from "lucide-react";
import { FIRST_RUN, SETTINGS_REGISTRY, registryText } from "@/lib/generated/registries";
import type { SeptenaApiClient } from "@/lib/api/client";
import { useEscapeToClose } from "@/lib/useEscapeToClose";

interface FirstRunModalProps {
  open: boolean;
  language: string;
  api: SeptenaApiClient;
  hasExistingTasks: boolean;
  onFinish: () => Promise<void>;
  onClose: () => void;
}

function settingsCopy(surface: keyof typeof SETTINGS_REGISTRY.copy, id: string, language: string): string {
  const entries = SETTINGS_REGISTRY.copy[surface] as readonly { id: string; label: string }[];
  const raw = entries.find((e) => e.id === id)?.label ?? "";
  return registryText(raw, language);
}

function formatTemplate(template: string, values: Record<string, string>): string {
  return template.replace(/\{([a-zA-Z0-9_]+)\}/g, (_, k: string) => values[k] ?? "");
}

export function FirstRunModal({
  open,
  language,
  api,
  hasExistingTasks,
  onFinish,
  onClose,
}: FirstRunModalProps) {
  const steps = useMemo(
    () =>
      FIRST_RUN.steps.filter((s) => {
        if ("platforms" in s && Array.isArray(s.platforms)) {
          return (s.platforms as readonly string[]).includes("web");
        }
        // Account step is skipped once signed in (web requires sign-in before shell).
        if (s.kind === "account") return false;
        return true;
      }),
    [],
  );

  const [stepIdx, setStepIdx] = useState(0);
  useEscapeToClose(open, onClose);
  const [copiedWhich, setCopiedWhich] = useState<"setup" | "url" | null>(null);
  const [codeExpanded, setCodeExpanded] = useState(false);
  const [pairCode, setPairCode] = useState("");
  const [pairPreview, setPairPreview] = useState<{ kind: "connector" | "device"; client: string } | null>(null);
  const [pairMessage, setPairMessage] = useState<string | null>(null);
  const [approved, setApproved] = useState(false);
  const initialAgentCount = useRef<number | null>(null);

  const step = steps[Math.min(stepIdx, steps.length - 1)];
  const isConnectStep = open && step?.kind === "connectAgent";

  // Detect an agent connected outside this modal (for example via email OAuth or headless signup)
  // when the user switches back to this tab.
  useEffect(() => {
    if (!isConnectStep || approved) return;
    let cancelled = false;

    const snapshotCount = async () => {
      try {
        const access = await api.getAccessSummary();
        if (cancelled) return;
        const count = access.connections.length;
        if (initialAgentCount.current === null) {
          initialAgentCount.current = count;
        } else if (count > initialAgentCount.current) {
          setApproved(true);
          setPairMessage(settingsCopy("sign_in_approval", "doneConnector", language));
        }
      } catch {
        // Offline or transient error: code approval still works.
      }
    };

    void snapshotCount();
    const onFocus = () => void snapshotCount();
    window.addEventListener("focus", onFocus);
    return () => {
      cancelled = true;
      window.removeEventListener("focus", onFocus);
    };
  }, [api, approved, isConnectStep, language]);

  if (!open || !step) return null;

  const closeLabel = registryText(
    FIRST_RUN.chrome.find((c) => c.id === "close")?.label ?? "Close",
    language,
  );
  const backLabel = registryText(
    FIRST_RUN.chrome.find((c) => c.id === "back")?.label ?? "Back",
    language,
  );
  const copiedLabel = settingsCopy("claude_connector", "copied", language);
  const copyLabel = settingsCopy("claude_connector", "copy", language);

  const copyValue = async (which: "setup" | "url") => {
    const text = which === "setup" ? FIRST_RUN.prompts.setup : FIRST_RUN.connectorUrl;
    try {
      await navigator.clipboard.writeText(text);
      setCopiedWhich(which);
      setTimeout(() => setCopiedWhich((prev) => (prev === which ? null : prev)), 2000);
    } catch {
      // Clipboard blocked.
    }
  };

  const inspectCode = async (e: React.FormEvent) => {
    e.preventDefault();
    const cleaned = pairCode.trim();
    if (!cleaned) return;
    setPairMessage(null);
    setPairPreview(null);
    try {
      const res = await api.inspectPairingCode(cleaned);
      setPairPreview({ kind: res.kind, client: res.client });
    } catch (err) {
      setPairMessage(
        err instanceof Error && err.message
          ? err.message
          : settingsCopy("sign_in_approval", "invalidCode", language),
      );
    }
  };

  const approveCode = async () => {
    if (!pairPreview) return;
    try {
      await api.approvePairingCode(pairCode.trim(), pairPreview.kind);
      setApproved(true);
      setPairPreview(null);
      setPairCode("");
      setPairMessage(settingsCopy("sign_in_approval", "doneConnector", language));
    } catch (err) {
      setPairMessage(
        err instanceof Error && err.message
          ? err.message
          : settingsCopy("sign_in_approval", "invalidCode", language),
      );
    }
  };

  const handleFinish = async () => {
    setStepIdx(0);
    await onFinish();
  };

  const renderPointIcon = (iconId: string) => {
    if (iconId === "onboarding.devices") return <MonitorSmartphone className="h-4 w-4 text-[var(--accent)]" />;
    if (iconId === "onboarding.agent") return <MessagesSquare className="h-4 w-4 text-[var(--accent)]" />;
    return <StickyNote className="h-4 w-4 text-[var(--accent)]" />;
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/45 p-4">
      <div className="w-full max-w-md overflow-hidden rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] shadow-2xl">
        <div className="flex items-center justify-between px-5 pt-4">
          <div className="flex items-center gap-1.5">
            {steps.map((s, idx) => (
              <span
                key={s.id}
                className={`h-1.5 rounded-full transition-all ${
                  idx === stepIdx ? "w-5 bg-[var(--accent)]" : "w-1.5 bg-[var(--border-subtle)]"
                }`}
              />
            ))}
          </div>
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)]"
            aria-label={closeLabel}
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="space-y-4 px-6 py-5">
          {step.kind === "intro" && (
            <>
              <div className="flex flex-col items-center text-center">
                <img src="/icon.svg" alt="" className="mb-3 h-12 w-12 rounded-xl shadow-sm" />
                <h2 className="text-xl font-semibold text-[var(--text-primary)]">
                  {registryText(step.title, language)}
                </h2>
                <p className="mt-1 text-sm text-[var(--text-secondary)]">
                  {registryText(step.body, language)}
                </p>
              </div>
              <div className="space-y-3 pt-2">
                {("points" in step ? step.points : []).map((pt) => (
                  <div key={pt.title} className="flex items-start gap-3">
                    <div className="mt-0.5 shrink-0">{renderPointIcon(pt.icon)}</div>
                    <div>
                      <p className="text-sm font-medium text-[var(--text-primary)]">
                        {registryText(pt.title, language)}
                      </p>
                      <p className="text-xs text-[var(--text-secondary)]">
                        {registryText(pt.detail, language)}
                      </p>
                    </div>
                  </div>
                ))}
              </div>
            </>
          )}

          {step.kind === "connectAgent" && (
            <>
              <div className="flex items-start gap-3">
                <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-[var(--bg-selected)] text-[var(--accent)]">
                  <Bot className="h-5 w-5" />
                </div>
                <div className="min-w-0">
                  <h2 className="text-lg font-semibold text-[var(--text-primary)]">
                    {registryText(step.title, language)}
                  </h2>
                  <p className="mt-0.5 text-xs leading-relaxed text-[var(--text-secondary)]">
                    {registryText(step.body, language)}
                  </p>
                </div>
              </div>

              {approved && pairMessage ? (
                <div className="flex items-start gap-2.5 rounded-xl border border-emerald-500/25 bg-emerald-500/10 px-3.5 py-3 text-xs text-[var(--text-primary)]">
                  <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-emerald-500" />
                  <span>{pairMessage}</span>
                </div>
              ) : (
                <div className="space-y-2.5">
                  <div className="rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-sidebar)] p-3.5">
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0">
                        <p className="text-xs font-medium text-[var(--text-primary)]">
                          {settingsCopy("claude_connector", "setupPrompt", language)}
                        </p>
                        <p className="mt-0.5 text-[11px] text-[var(--text-secondary)]">
                          {settingsCopy("claude_connector", "setupPromptDetail", language)}
                        </p>
                      </div>
                    </div>
                    <button
                      type="button"
                      onClick={() => void copyValue("setup")}
                      className="mt-3 inline-flex w-full items-center justify-center gap-1.5 rounded-lg bg-[var(--accent)] px-3 py-2 text-xs font-medium transition-opacity hover:opacity-95"
                      style={{ color: "var(--accent-check)" }}
                    >
                      {copiedWhich === "setup" ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
                      {copiedWhich === "setup"
                        ? copiedLabel
                        : registryText("primary" in step ? step.primary.title : "Copy setup prompt", language)}
                    </button>
                  </div>

                  <div className="rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-sidebar)] p-3.5">
                    <div className="flex items-center justify-between gap-3">
                      <div className="min-w-0">
                        <p className="text-xs font-medium text-[var(--text-primary)]">
                          {settingsCopy("claude_connector", "connectorUrl", language)}
                        </p>
                        <p className="font-mono-tabular mt-0.5 truncate text-[11px] text-[var(--text-secondary)] select-all">
                          {FIRST_RUN.connectorUrl}
                        </p>
                      </div>
                      <button
                        type="button"
                        onClick={() => void copyValue("url")}
                        className="inline-flex shrink-0 items-center gap-1 rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-elevated)] px-2.5 py-1.5 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                      >
                        {copiedWhich === "url" ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
                        {copiedWhich === "url" ? copiedLabel : copyLabel}
                      </button>
                    </div>
                    <p className="mt-1.5 text-[11px] text-[var(--text-muted)]">
                      {settingsCopy("claude_connector", "connectorUrlDetail", language)}
                    </p>
                  </div>

                  <div className="pt-0.5">
                    <button
                      type="button"
                      onClick={() => setCodeExpanded((openCode) => !openCode)}
                      aria-expanded={codeExpanded}
                      className="inline-flex items-center gap-1 text-xs font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                    >
                      {codeExpanded ? <ChevronDown className="h-3.5 w-3.5" /> : <ChevronRight className="h-3.5 w-3.5" />}
                      {settingsCopy("claude_connector", "haveCode", language)}
                    </button>

                    {codeExpanded && (
                      <div className="mt-2 space-y-2 rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-sidebar)] p-3">
                        <p className="text-[11px] leading-relaxed text-[var(--text-secondary)]">
                          {settingsCopy("claude_connector", "codeHint", language)}
                        </p>
                        <form onSubmit={(e) => void inspectCode(e)} className="flex gap-2">
                          <input
                            type="text"
                            value={pairCode}
                            onChange={(e) => setPairCode(e.target.value.toUpperCase())}
                            placeholder={settingsCopy("claude_connector", "codePlaceholder", language)}
                            autoCapitalize="characters"
                            autoCorrect="off"
                            spellCheck={false}
                            className="font-mono-tabular min-w-0 flex-1 rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-elevated)] px-3 py-1.5 text-xs tracking-wider text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                          />
                          <button
                            type="submit"
                            disabled={!pairCode.trim()}
                            className="rounded-lg bg-[var(--bg-hover)] px-3 py-1.5 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-selected)] disabled:opacity-45"
                          >
                            {settingsCopy("sign_in_approval", "continue", language)}
                          </button>
                        </form>

                        {pairPreview && (
                          <div className="flex items-center justify-between gap-2 rounded-lg bg-[var(--bg-elevated)] px-3 py-2 text-xs">
                            <span className="text-[var(--text-primary)]">
                              {formatTemplate(
                                settingsCopy(
                                  "sign_in_approval",
                                  pairPreview.kind === "device" ? "confirmDevice" : "confirmConnector",
                                  language,
                                ),
                                { client: pairPreview.client },
                              )}
                            </span>
                            <button
                              type="button"
                              onClick={() => void approveCode()}
                              className="shrink-0 rounded-md bg-[var(--accent)] px-2.5 py-1 font-medium"
                              style={{ color: "var(--accent-check)" }}
                            >
                              {settingsCopy("sign_in_approval", "approve", language)}
                            </button>
                          </div>
                        )}
                        {pairMessage && !approved && (
                          <p className="text-[11px] text-[var(--text-secondary)]">{pairMessage}</p>
                        )}
                      </div>
                    )}
                  </div>
                </div>
              )}
            </>
          )}

          {step.kind === "finish" && (
            <div className="flex flex-col items-center py-4 text-center">
              <CheckCircle2 className="mb-3 h-10 w-10 text-emerald-500" />
              <h2 className="text-xl font-semibold text-[var(--text-primary)]">
                {registryText(
                  hasExistingTasks && "returningTitle" in step ? step.returningTitle : step.title,
                  language,
                )}
              </h2>
              <p className="mt-1.5 text-sm text-[var(--text-secondary)]">
                {registryText(
                  hasExistingTasks && "returningBody" in step ? step.returningBody : step.body,
                  language,
                )}
              </p>
            </div>
          )}
        </div>

        <div className="flex items-center justify-between border-t border-[var(--border-subtle)] px-6 py-3.5 text-xs">
          {stepIdx > 0 && step.kind !== "finish" ? (
            <button
              type="button"
              onClick={() => setStepIdx((i) => Math.max(0, i - 1))}
              className="rounded-lg px-3 py-1.5 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
            >
              {backLabel}
            </button>
          ) : (
            <span />
          )}

          <div className="flex items-center gap-2">
            {step.kind === "finish" ? (
              <button
                type="button"
                onClick={() => void handleFinish()}
                className="rounded-lg bg-[var(--accent)] px-4 py-1.5 font-medium"
                style={{ color: "var(--accent-check)" }}
              >
                {registryText("primary" in step ? step.primary.title : "Open Today", language)}
              </button>
            ) : step.kind === "connectAgent" ? (
              approved ? (
                <button
                  type="button"
                  onClick={() => setStepIdx((i) => Math.min(steps.length - 1, i + 1))}
                  className="rounded-lg bg-[var(--accent)] px-4 py-1.5 font-medium"
                  style={{ color: "var(--accent-check)" }}
                >
                  {registryText("afterDone" in step ? step.afterDone.title : "Continue", language)}
                </button>
              ) : (
                <button
                  type="button"
                  onClick={() => setStepIdx((i) => Math.min(steps.length - 1, i + 1))}
                  className="rounded-lg bg-[var(--bg-hover)] px-3.5 py-1.5 font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                >
                  {registryText("secondary" in step ? step.secondary.title : "Skip", language)}
                </button>
              )
            ) : (
              <button
                type="button"
                onClick={() => setStepIdx((i) => Math.min(steps.length - 1, i + 1))}
                className="rounded-lg bg-[var(--accent)] px-4 py-1.5 font-medium"
                style={{ color: "var(--accent-check)" }}
              >
                {registryText("primary" in step ? step.primary.title : "Continue", language)}
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
