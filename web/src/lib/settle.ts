// Standard task-completion settle window (`registry/tokens.json` `motion.completion`,
// `docs/DesignSpec.md` §9). A just-completed (or cancelled) row lingers in place
// struck through so the user sees the completion land and can tap again to undo,
// then smoothly fades out of the open list.

import { DESIGN_TOKENS } from "./generated/registries.ts";

export const COMPLETION_MOTION = DESIGN_TOKENS.motion.completion;

export interface SettleEntry {
  /** Whether the row is in the final fade-out beat (`fadeOutMs`). */
  fadingOut: boolean;
  /** Review group held while settling in Review (so accepted rows don't jump). */
  reviewGroup?: string | null;
}

export interface SettleSnapshot {
  entries: ReadonlyMap<string, SettleEntry>;
}

interface TimerPair {
  fadeTimer: ReturnType<typeof setTimeout>;
  doneTimer: ReturnType<typeof setTimeout>;
}

/**
 * Pure timer controller for the completion settle window, shared by React
 * components and unit tests. Re-scheduling an id restarts its clock; cancelling
 * aborts the fade-out cleanly.
 */
export class CompletionSettleController {
  private entries = new Map<string, SettleEntry>();
  private timers = new Map<string, TimerPair>();
  private listeners = new Set<() => void>();
  private snapshot: SettleSnapshot = { entries: new Map() };
  private readonly settleDelayMs: number;
  private readonly fadeOutMs: number;

  constructor(
    settleDelayMs: number = COMPLETION_MOTION.settleDelayMs,
    fadeOutMs: number = COMPLETION_MOTION.fadeOutMs,
  ) {
    this.settleDelayMs = settleDelayMs;
    this.fadeOutMs = fadeOutMs;
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  getSnapshot(): SettleSnapshot {
    return this.snapshot;
  }

  isSettling(id: string): boolean {
    return this.entries.has(id);
  }

  isFadingOut(id: string): boolean {
    return this.entries.get(id)?.fadingOut === true;
  }

  reviewGroupOf(id: string): string | null | undefined {
    return this.entries.get(id)?.reviewGroup;
  }

  start(id: string, opts?: { reviewGroup?: string | null }): void {
    this.clearTimers(id);
    this.entries.set(id, { fadingOut: false, reviewGroup: opts?.reviewGroup });
    const fadeTimer = setTimeout(() => {
      const current = this.entries.get(id);
      if (!current) return;
      this.entries.set(id, { ...current, fadingOut: true });
      this.emit();
    }, this.settleDelayMs);
    const doneTimer = setTimeout(() => {
      this.timers.delete(id);
      if (this.entries.delete(id)) this.emit();
    }, this.settleDelayMs + this.fadeOutMs);
    this.timers.set(id, { fadeTimer, doneTimer });
    this.emit();
  }

  cancel(id: string): void {
    this.clearTimers(id);
    if (this.entries.delete(id)) this.emit();
  }

  clearAll(): void {
    if (this.entries.size === 0 && this.timers.size === 0) return;
    for (const pair of this.timers.values()) {
      clearTimeout(pair.fadeTimer);
      clearTimeout(pair.doneTimer);
    }
    this.timers.clear();
    this.entries.clear();
    this.emit();
  }

  private clearTimers(id: string): void {
    const existing = this.timers.get(id);
    if (!existing) return;
    clearTimeout(existing.fadeTimer);
    clearTimeout(existing.doneTimer);
    this.timers.delete(id);
  }

  private emit(): void {
    this.snapshot = { entries: new Map(this.entries) };
    for (const fn of this.listeners) fn();
  }
}
