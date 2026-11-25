"use client";

import { useMemo, useState } from "react";
import { Bot, Check, CheckCircle2, Copy, MessagesSquare, MonitorSmartphone, StickyNote, X } from "lucide-react";
import { FIRST_RUN, registryText } from "@/lib/generated/registries";
import type { SeptenaApiClient } from "@/lib/api/client";

interface FirstRunModalProps {
  open: boolean;
  language: string;
  api: SeptenaApiClient;
  hasExistingTasks: boolean;
  onFinish: () => Promise<void>;
  onClose: () => void;
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
  const [copiedWhich, setCopiedWhich] = useState<"setup" | "first" | null>(null);
  const [pairCode, setPairCode] = useState("");
  const [pairPreview, setPairPreview] = useState<{ kind: "connector" | "device"; client: string } | null>(null);
  const [pairMessage, setPairMessage] = useState<string | null>(null);
  const [approved, setApproved] = useState(false);

  if (!open) return null;

  const step = steps[Math.min(stepIdx, steps.length - 1)];

  const copyPrompt = async (which: "setup" | "first") => {
    const text = which === "setup" ? FIRST_RUN.prompts.setup : FIRST_RUN.prompts.first;
    try {
      await navigator.clipboard.writeText(text);
      setCopiedWhich(which);
      setTimeout(() => setCopiedWhich(null), 2000);
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
      setPairMessage(err instanceof Error ? err.message : "That code is wrong or has expired.");
    }
  };

  const approveCode = async () => {
    if (!pairPreview) return;
    try {
      await api.approvePairingCode(pairCode.trim(), pairPreview.kind);
      setApproved(true);
      setPairPreview(null);
      setPairCode("");
      setPairMessage("Claude is connected. Go back to your browser to finish.");
    } catch (err) {
      setPairMessage(err instanceof Error ? err.message : "Approval failed.");
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
            aria-label="Close welcome"
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
              <div className="flex items-center gap-3">
                <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-[var(--bg-selected)] text-[var(--accent)]">
                  <Bot className="h-5 w-5" />
                </div>
                <div>
                  <h2 className="text-lg font-semibold text-[var(--text-primary)]">
                    {registryText(step.title, language)}
                  </h2>
                  <p className="text-xs text-[var(--text-secondary)]">
                    {registryText(step.body, language)}
                  </p>
                </div>
              </div>

              <ol className="list-decimal space-y-1.5 pl-4 text-xs text-[var(--text-secondary)]">
                {("instructions" in step ? step.instructions : []).map((line) => (
                  <li key={line}>{registryText(line, language)}</li>
                ))}
              </ol>

              <div className="flex flex-wrap gap-2">
                <button
                  type="button"
                  onClick={() => void copyPrompt("setup")}
                  className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--accent)] px-3 py-1.5 text-xs font-medium"
                  style={{ color: "var(--accent-check)" }}
                >
                  {copiedWhich === "setup" ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
                  {copiedWhich === "setup" ? "Copied" : "Copy setup prompt"}
                </button>
                <button
                  type="button"
                  onClick={() => void copyPrompt("first")}
                  className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-3 py-1.5 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                >
                  {copiedWhich === "first" ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
                  {copiedWhich === "first" ? "Copied" : "Copy first prompt"}
                </button>
              </div>

              <form onSubmit={(e) => void inspectCode(e)} className="flex gap-2 pt-1">
                <input
                  type="text"
                  value={pairCode}
                  onChange={(e) => setPairCode(e.target.value)}
                  placeholder="Code from the browser page"
                  className="font-mono-tabular min-w-0 flex-1 rounded-lg border border-[var(--border-subtle)] bg-transparent px-3 py-1.5 text-xs text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                />
                <button
                  type="submit"
                  className="rounded-lg bg-[var(--bg-hover)] px-3 py-1.5 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-selected)]"
                >
                  Continue
                </button>
              </form>

              {pairPreview && (
                <div className="flex items-center justify-between rounded-lg bg-[var(--bg-hover)] px-3 py-2 text-xs">
                  <span>
                    Connect <strong>{pairPreview.client}</strong>?
                  </span>
                  <button
                    type="button"
                    onClick={() => void approveCode()}
                    className="rounded-md bg-[var(--accent)] px-2.5 py-1 font-medium"
                    style={{ color: "var(--accent-check)" }}
                  >
                    Approve
                  </button>
                </div>
              )}
              {pairMessage && <p className="text-xs text-[var(--text-secondary)]">{pairMessage}</p>}
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
              Back
            </button>
          ) : (
            <span />
          )}

          <div className="flex items-center gap-2">
            {step.kind === "connectAgent" && !approved && (
              <button
                type="button"
                onClick={() => setStepIdx((i) => i + 1)}
                className="rounded-lg bg-[var(--bg-hover)] px-3.5 py-1.5 font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
              >
                Later
              </button>
            )}
            {step.kind === "finish" ? (
              <button
                type="button"
                onClick={() => void handleFinish()}
                className="rounded-lg bg-[var(--accent)] px-4 py-1.5 font-medium"
                style={{ color: "var(--accent-check)" }}
              >
                Open Today
              </button>
            ) : (
              <button
                type="button"
                onClick={() => setStepIdx((i) => Math.min(steps.length - 1, i + 1))}
                className="rounded-lg bg-[var(--accent)] px-4 py-1.5 font-medium"
                style={{ color: "var(--accent-check)" }}
              >
                Continue
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
