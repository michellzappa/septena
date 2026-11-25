// Single shared undo/redo stack for the web app (mirrors SeptenaCore/TaskUndo.swift).
// Recorded ONLY at user gestures, never inside sync applies.

export interface UndoEntry {
  label: string;
  undo: () => Promise<void>;
  redo: () => Promise<void>;
}

export interface UndoSnapshot {
  canUndo: boolean;
  canRedo: boolean;
  undoLabel: string | null;
  redoLabel: string | null;
  toast: { label: string; id: number } | null;
}

const MAX_STACK = 50;

export class UndoStack {
  private undoStack: UndoEntry[] = [];
  private redoStack: UndoEntry[] = [];
  private listeners = new Set<(s: UndoSnapshot) => void>();
  private toast: { label: string; id: number } | null = null;
  private toastSeq = 0;
  private toastTimer: ReturnType<typeof setTimeout> | null = null;

  getSnapshot(): UndoSnapshot {
    return {
      canUndo: this.undoStack.length > 0,
      canRedo: this.redoStack.length > 0,
      undoLabel: this.undoStack[this.undoStack.length - 1]?.label ?? null,
      redoLabel: this.redoStack[this.redoStack.length - 1]?.label ?? null,
      toast: this.toast,
    };
  }

  subscribe(fn: (s: UndoSnapshot) => void): () => void {
    this.listeners.add(fn);
    fn(this.getSnapshot());
    return () => this.listeners.delete(fn);
  }

  private emit(): void {
    const snap = this.getSnapshot();
    for (const fn of this.listeners) fn(snap);
  }

  record(entry: UndoEntry, showToast = false): void {
    this.undoStack.push(entry);
    if (this.undoStack.length > MAX_STACK) this.undoStack.shift();
    this.redoStack = [];
    if (showToast) {
      this.showToast(entry.label);
    } else {
      this.emit();
    }
  }

  showToast(label: string): void {
    if (this.toastTimer) clearTimeout(this.toastTimer);
    this.toast = { label, id: ++this.toastSeq };
    this.emit();
    this.toastTimer = setTimeout(() => {
      this.toast = null;
      this.emit();
    }, 4500);
  }

  dismissToast(): void {
    if (this.toastTimer) clearTimeout(this.toastTimer);
    this.toast = null;
    this.emit();
  }

  async undo(): Promise<void> {
    const entry = this.undoStack.pop();
    if (!entry) return;
    this.redoStack.push(entry);
    this.toast = null;
    this.emit();
    await entry.undo();
  }

  async redo(): Promise<void> {
    const entry = this.redoStack.pop();
    if (!entry) return;
    this.undoStack.push(entry);
    this.toast = null;
    this.emit();
    await entry.redo();
  }

  clear(): void {
    if (this.toastTimer) clearTimeout(this.toastTimer);
    this.undoStack = [];
    this.redoStack = [];
    this.toast = null;
    this.emit();
  }
}
