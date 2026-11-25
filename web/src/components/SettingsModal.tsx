"use client";

import { useCallback, useEffect, useState } from "react";
import { Check, Download, Laptop, LogOut, PauseCircle, PlayCircle, ShieldCheck, Sparkles, Trash2, X } from "lucide-react";
import { DESIGN_TOKENS, REGISTRY_LANGUAGES, registryText } from "@/lib/generated/registries";
import { exportAsCsv, exportAsJson, exportAsMarkdown } from "@/lib/export";
import type { SeptenaApiClient } from "@/lib/api/client";
import type { WebSyncEngine } from "@/lib/sync/engine";
import type { AccessSummary, StoreSnapshot } from "@/lib/types";

interface SettingsModalProps {
  open: boolean;
  onClose: () => void;
  api: SeptenaApiClient;
  engine: WebSyncEngine;
  snapshot: StoreSnapshot;
  coreVersion: string;
  appearanceMode: "system" | "light" | "dark";
  onChangeAppearanceMode: (mode: "system" | "light" | "dark") => void;
  textScaleStep: number;
  onChangeTextScaleStep: (step: number) => void;
  language: string;
  onChangeLanguage: (lang: string) => void;
  onSignOut: () => void;
}

export function SettingsModal({
  open,
  onClose,
  api,
  engine,
  snapshot,
  coreVersion,
  appearanceMode,
  onChangeAppearanceMode,
  textScaleStep,
  onChangeTextScaleStep,
  language,
  onChangeLanguage,
  onSignOut,
}: SettingsModalProps) {
  const [tab, setTab] = useState<"appearance" | "agents" | "data">("appearance");
  const [access, setAccess] = useState<AccessSummary | null>(null);
  const [accessError, setAccessError] = useState<string | null>(null);
  const [pairCode, setPairCode] = useState("");
  const [pairPreview, setPairPreview] = useState<{ kind: "connector" | "device"; client: string } | null>(null);
  const [pairStatus, setPairStatus] = useState<string | null>(null);

  const loadAccess = useCallback(async () => {
    setAccessError(null);
    try {
      setAccess(await api.getAccessSummary());
    } catch (err) {
      setAccessError(err instanceof Error ? err.message : "Could not load devices & agents");
    }
  }, [api]);

  useEffect(() => {
    if (open && tab === "agents") {
      void loadAccess();
    }
  }, [loadAccess, open, tab]);

  if (!open) return null;

  const currentAccent = typeof snapshot.settings.accentColor === "string"
    ? snapshot.settings.accentColor
    : "colorful";
  const agentsPaused = Boolean(snapshot.settings.agentsPaused);

  const handleInspectCode = async (e: React.FormEvent) => {
    e.preventDefault();
    const cleaned = pairCode.trim();
    if (!cleaned) return;
    setPairStatus(null);
    setPairPreview(null);
    try {
      const res = await api.inspectPairingCode(cleaned);
      setPairPreview({ kind: res.kind, client: res.client });
    } catch (err) {
      setPairStatus(err instanceof Error ? err.message : "Code not recognized");
    }
  };

  const handleApproveCode = async () => {
    if (!pairPreview) return;
    try {
      await api.approvePairingCode(pairCode.trim(), pairPreview.kind);
      setPairStatus(`Approved ${pairPreview.client}`);
      setPairPreview(null);
      setPairCode("");
      void loadAccess();
    } catch (err) {
      setPairStatus(err instanceof Error ? err.message : "Approval failed");
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
      onClick={onClose}
    >
      <div
        className="flex max-h-[85vh] w-full max-w-xl flex-col overflow-hidden rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between border-b border-[var(--border-subtle)] px-5 py-3.5">
          <h2 className="text-base font-semibold text-[var(--text-primary)]">
            {registryText("Settings", language)}
          </h2>
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)]"
            aria-label="Close settings"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="flex gap-1 border-b border-[var(--border-subtle)] px-4 py-2 text-xs">
          {(["appearance", "agents", "data"] as const).map((t) => (
            <button
              key={t}
              type="button"
              onClick={() => setTab(t)}
              className={`rounded-lg px-3 py-1.5 font-medium transition-colors ${
                tab === t
                  ? "bg-[var(--bg-selected)] text-[var(--text-primary)]"
                  : "text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
              }`}
            >
              {t === "appearance" && "Appearance"}
              {t === "agents" && "Devices & Agents"}
              {t === "data" && "Data & Account"}
            </button>
          ))}
        </div>

        <div className="flex-1 space-y-6 overflow-y-auto p-5 text-sm">
          {tab === "appearance" && (
            <>
              <section>
                <h3 className="mb-2 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                  Appearance
                </h3>
                <div className="grid grid-cols-3 gap-2">
                  {(["system", "light", "dark"] as const).map((m) => (
                    <button
                      key={m}
                      type="button"
                      onClick={() => onChangeAppearanceMode(m)}
                      className={`rounded-lg border px-3 py-2 text-xs font-medium capitalize transition-colors ${
                        appearanceMode === m
                          ? "border-[var(--accent)] bg-[var(--bg-selected)] text-[var(--text-primary)]"
                          : "border-[var(--border-subtle)] text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
                      }`}
                    >
                      {m}
                    </button>
                  ))}
                </div>
              </section>

              <section>
                <h3 className="mb-2 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                  Accent color (synced)
                </h3>
                <div className="grid grid-cols-3 gap-2">
                  {DESIGN_TOKENS.fruitAccents.map((fruit) => {
                    const selected = currentAccent === fruit.id;
                    return (
                      <button
                        key={fruit.id}
                        type="button"
                        onClick={() => void engine.setSetting("accentColor", fruit.id)}
                        className={`flex items-center gap-2 rounded-lg border px-2.5 py-2 text-left text-xs transition-colors ${
                          selected
                            ? "border-[var(--accent)] bg-[var(--bg-selected)] text-[var(--text-primary)]"
                            : "border-[var(--border-subtle)] text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
                        }`}
                      >
                        <span
                          className="h-3.5 w-3.5 shrink-0 rounded-full"
                          style={{ backgroundColor: fruit.light }}
                        />
                        <span className="truncate font-medium">{fruit.name}</span>
                        {selected && <Check className="ml-auto h-3.5 w-3.5 shrink-0" />}
                      </button>
                    );
                  })}
                </div>
              </section>

              <section>
                <h3 className="mb-2 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                  Text size
                </h3>
                <div className="grid grid-cols-5 gap-1.5">
                  {DESIGN_TOKENS.textScale.steps.map((s) => (
                    <button
                      key={s.id}
                      type="button"
                      onClick={() => onChangeTextScaleStep(s.step)}
                      className={`rounded-lg border px-2 py-1.5 text-xs transition-colors ${
                        textScaleStep === s.step
                          ? "border-[var(--accent)] bg-[var(--bg-selected)] font-medium text-[var(--text-primary)]"
                          : "border-[var(--border-subtle)] text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
                      }`}
                    >
                      {s.label}
                    </button>
                  ))}
                </div>
              </section>

              <section>
                <h3 className="mb-2 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                  Language
                </h3>
                <div className="flex gap-2">
                  {REGISTRY_LANGUAGES.map((lang) => (
                    <button
                      key={lang}
                      type="button"
                      onClick={() => onChangeLanguage(lang)}
                      className={`rounded-lg border px-3 py-1.5 text-xs font-medium transition-colors ${
                        language === lang
                          ? "border-[var(--accent)] bg-[var(--bg-selected)] text-[var(--text-primary)]"
                          : "border-[var(--border-subtle)] text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
                      }`}
                    >
                      {lang}
                    </button>
                  ))}
                </div>
              </section>
            </>
          )}

          {tab === "agents" && (
            <>
              <section className="flex items-center justify-between rounded-xl border border-[var(--border-subtle)] p-3.5">
                <div>
                  <p className="font-medium text-[var(--text-primary)]">Pause all agents</p>
                  <p className="text-xs text-[var(--text-muted)]">
                    Stops connected agents from claiming or editing tasks until resumed.
                  </p>
                </div>
                <button
                  type="button"
                  onClick={() => void engine.setSetting("agentsPaused", !agentsPaused)}
                  className={`inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium ${
                    agentsPaused
                      ? "bg-amber-500/15 text-amber-600 dark:text-amber-400"
                      : "bg-[var(--bg-hover)] text-[var(--text-primary)]"
                  }`}
                >
                  {agentsPaused ? <PlayCircle className="h-3.5 w-3.5" /> : <PauseCircle className="h-3.5 w-3.5" />}
                  {agentsPaused ? "Paused — Resume" : "Pause all"}
                </button>
              </section>

              <section className="rounded-xl border border-[var(--border-subtle)] p-3.5">
                <h3 className="mb-2 flex items-center gap-1.5 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                  <ShieldCheck className="h-3.5 w-3.5" />
                  Approve a device or agent
                </h3>
                <form onSubmit={(e) => void handleInspectCode(e)} className="flex gap-2">
                  <input
                    type="text"
                    value={pairCode}
                    onChange={(e) => setPairCode(e.target.value)}
                    placeholder="Enter 8-character code (e.g. ABCD-EFGH)"
                    className="font-mono-tabular min-w-0 flex-1 rounded-lg border border-[var(--border-subtle)] bg-transparent px-3 py-1.5 text-xs text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                  />
                  <button
                    type="submit"
                    className="rounded-lg bg-[var(--accent)] px-3 py-1.5 text-xs font-medium text-white hover:opacity-90"
                  >
                    Inspect
                  </button>
                </form>
                {pairPreview && (
                  <div className="mt-3 flex items-center justify-between rounded-lg bg-[var(--bg-hover)] p-2.5 text-xs">
                    <span>
                      Approve <strong>{pairPreview.client}</strong> ({pairPreview.kind})?
                    </span>
                    <button
                      type="button"
                      onClick={() => void handleApproveCode()}
                      className="rounded-md bg-[var(--accent)] px-2.5 py-1 font-medium text-white"
                    >
                      Approve
                    </button>
                  </div>
                )}
                {pairStatus && <p className="mt-2 text-xs text-[var(--text-secondary)]">{pairStatus}</p>}
              </section>

              {accessError && <p className="text-xs text-[var(--overdue-red)]">{accessError}</p>}

              {access && (
                <>
                  <section>
                    <h3 className="mb-2 flex items-center gap-1.5 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                      <Sparkles className="h-3.5 w-3.5" />
                      Connected agents ({access.connections.length})
                    </h3>
                    {access.connections.length === 0 ? (
                      <p className="text-xs text-[var(--text-muted)]">No agents connected.</p>
                    ) : (
                      <div className="space-y-1.5">
                        {access.connections.map((conn) => (
                          <div
                            key={conn.id}
                            className="flex items-center justify-between rounded-lg border border-[var(--border-subtle)] px-3 py-2 text-xs"
                          >
                            <div>
                              <p className="font-medium text-[var(--text-primary)]">
                                {conn.name || conn.clientName || conn.clientId || "Agent"}
                              </p>
                              <p className="text-[var(--text-muted)]">
                                {conn.lastUsedAt
                                  ? `Last active ${new Date(conn.lastUsedAt).toLocaleDateString()}`
                                  : "Connected"}
                              </p>
                            </div>
                            <button
                              type="button"
                              onClick={async () => {
                                await api.disconnectAgent(conn.id);
                                void loadAccess();
                              }}
                              className="inline-flex items-center gap-1 rounded px-2 py-1 text-[var(--overdue-red)] hover:bg-[var(--overdue-red)]/10"
                            >
                              <Trash2 className="h-3 w-3" />
                              Disconnect
                            </button>
                          </div>
                        ))}
                      </div>
                    )}
                  </section>

                  <section>
                    <h3 className="mb-2 flex items-center gap-1.5 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                      <Laptop className="h-3.5 w-3.5" />
                      Signed-in devices ({access.devices.length})
                    </h3>
                    <div className="space-y-1.5">
                      {access.devices.map((dev) => (
                        <div
                          key={dev.sid}
                          className="flex items-center justify-between rounded-lg border border-[var(--border-subtle)] px-3 py-2 text-xs"
                        >
                          <div>
                            <p className="font-medium text-[var(--text-primary)]">
                              {dev.client || "Septena device"}
                              {dev.current && (
                                <span className="ml-2 rounded bg-[var(--bg-selected)] px-1.5 py-0.5 text-[10px]">
                                  This browser
                                </span>
                              )}
                            </p>
                          </div>
                          {!dev.current && (
                            <button
                              type="button"
                              onClick={async () => {
                                await api.revokeDevice(dev.sid);
                                void loadAccess();
                              }}
                              className="rounded px-2 py-1 text-[var(--overdue-red)] hover:bg-[var(--overdue-red)]/10"
                            >
                              Sign out
                            </button>
                          )}
                        </div>
                      ))}
                    </div>
                  </section>
                </>
              )}
            </>
          )}

          {tab === "data" && (
            <>
              <section>
                <h3 className="mb-2 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                  Export your tasks (always free)
                </h3>
                <div className="flex flex-wrap gap-2">
                  <button
                    type="button"
                    onClick={() => exportAsJson(snapshot)}
                    className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-3 py-2 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                  >
                    <Download className="h-3.5 w-3.5" />
                    Export JSON
                  </button>
                  <button
                    type="button"
                    onClick={() => exportAsMarkdown(snapshot)}
                    className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-3 py-2 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                  >
                    <Download className="h-3.5 w-3.5" />
                    Export Markdown
                  </button>
                  <button
                    type="button"
                    onClick={() => exportAsCsv(snapshot)}
                    className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-3 py-2 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                  >
                    <Download className="h-3.5 w-3.5" />
                    Export CSV
                  </button>
                </div>
              </section>

              <section className="rounded-xl border border-[var(--border-subtle)] p-3.5 text-xs text-[var(--text-secondary)]">
                <p className="font-mono-tabular">
                  Shared Rust core WASM: v{coreVersion} · Revision: {snapshot.cursor} · Queued ops:{" "}
                  {snapshot.outbox.length}
                </p>
                <p className="mt-1 text-[var(--text-muted)]">
                  Tasks: {snapshot.tasks.length} · Areas: {snapshot.areas.length} · Projects:{" "}
                  {snapshot.projects.length} · Tags: {snapshot.tags.length} · Checklists:{" "}
                  {snapshot.checklistItems.length}
                </p>
              </section>

              <section className="border-t border-[var(--border-subtle)] pt-4">
                <button
                  type="button"
                  onClick={() => {
                    onClose();
                    onSignOut();
                  }}
                  className="inline-flex items-center gap-2 rounded-lg border border-[var(--overdue-red)]/30 px-3.5 py-2 text-xs font-medium text-[var(--overdue-red)] hover:bg-[var(--overdue-red)]/10"
                >
                  <LogOut className="h-3.5 w-3.5" />
                  Sign out and clear local browser data
                </button>
              </section>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
