# How AI helps with your tasks

Plain-language explainer for users. Source of truth — the in-app screen
(`AIExplainerView`) and, later, the website both draw from this. Keep it short,
concrete, and jargon-free.

---

## Headline
**Some to-dos need a moment of thinking before you can act. Septena can talk that
through with AI — right on the task.**

## The short version
A task can hold a short, tap-to-answer conversation. The AI asks what you actually
mean, does the parts it can, and hands you the one step only you can take.

## How it works — four plain rules

**1. It asks before it does anything.**
The AI never guesses what a vague task means. It shows you a couple of readings;
you tap the right one. Nothing happens until you do.

**2. You answer by tapping, not typing.**
Each step is a question with a few buttons (plus "Other…" if none fit). One tap
moves it forward. It's a conversation made of choices, not a chat box.

**3. It does what it can, and hands you the rest.**
If the AI can do the work — look something up, draft something, compare options —
it does, and shows you the result. If only you can finish it (pay, send, decide),
it gives you one clear button to do that.

**4. The dot tells you whose turn it is.**
- 🟡 **Your turn** — there's a question waiting for you
- 🔵 **AI's turn** — it's working on it
- ✅ **Done**

## The steps, one by one (what actually happens)

```
 Capture  →  Confirm  →  Ground  →   Decide   →    Work     →  Hand off
 (you)      (on-device) (on-device) (on-device↗) (on-device↗)   (you)
                                      ↗ = leaves the device only if a step needs more
```

1. **Capture** — *you.* Jot the task; a few words is fine.
2. **Confirm** — *on-device.* AI asks what you actually mean. Nothing happens until you tap.
3. **Ground** — *on-device.* It pulls the relevant context from your own data.
4. **Decide** — *on-device, or cloud if needed.* It offers a few options; you pick. Only a genuinely hard call reaches for Private Cloud Compute or your Claude.
5. **Work** — *on-device, or your Claude.* It does what it can (a draft, a comparison). The web or your Claude is used only when a step truly needs it.
6. **Hand off** — *you.* Anything only you can do (pay, send, decide) becomes one clear button.

On **Automatic**, every step runs **on your device first**; it leaves the device
only for the specific steps on-device can't do — never wholesale.

## Some help is always on-device
Beyond conversations, Septena learns small things **locally** — like the
**"Move to…" suggestion** that figures out where a task belongs from your own
history (and the inbox triage behind it). That's a model trained on your device,
on your data; it never leaves, with or without the conversation feature.

## The part that matters most: it's *your* AI

**Septena never runs AI on your tasks, and never reads them.** The intelligence is
**your own** — your Claude, or (later) on-device Apple Intelligence — connected by
you. Your tasks live only in your private iCloud; there's no Septena server in the
middle.

Turn the AI off and the app works exactly the same, just without the conversations.
You're never locked in, and you're never paying us for AI.

## Nothing important happens on its own
The AI fills in the small, reversible stuff. Anything that's a real decision, or
can't be undone, **always waits for your tap.** You're in control of every step.

---

### One-line version (for tooltips / app store)
*Turn a vague to-do into a clear next step — your AI asks, you tap, it's done. Your
data never leaves your iCloud.*
