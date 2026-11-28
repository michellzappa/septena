"use client";

import { useEffect, useRef } from "react";

// Escape closes the top open modal, sheet or dialog (Settings, Support, Quick
// Find, pickers, the task page). Every surface that covers the app registers
// here while it is open, so one key press closes one layer: a dialog on top
// of Settings closes first, then Settings on the next press. Focus does not
// matter: the listener sits on the window.

const stack: symbol[] = [];
let listening = false;
const handlers = new Map<symbol, () => void>();

function onKeyDown(e: KeyboardEvent) {
  if (e.key !== "Escape" || e.isComposing) return;
  const top = stack[stack.length - 1];
  if (!top) return;
  e.preventDefault();
  e.stopImmediatePropagation();
  handlers.get(top)?.();
}

/** Closes this surface on Escape while `open`, when it is the top one. */
export function useEscapeToClose(open: boolean, onClose: () => void): void {
  const close = useRef(onClose);
  close.current = onClose;

  useEffect(() => {
    if (!open) return;
    const id = Symbol("escape-layer");
    stack.push(id);
    handlers.set(id, () => close.current());
    if (!listening) {
      // Capture phase, so the app's own Escape (clear the selection) does not
      // also run while a modal is open.
      window.addEventListener("keydown", onKeyDown, true);
      listening = true;
    }
    return () => {
      const at = stack.lastIndexOf(id);
      if (at >= 0) stack.splice(at, 1);
      handlers.delete(id);
      if (stack.length === 0 && listening) {
        window.removeEventListener("keydown", onKeyDown, true);
        listening = false;
      }
    };
  }, [open]);
}
