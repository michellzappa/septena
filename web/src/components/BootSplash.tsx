import { registryText, SIGN_IN } from "@/lib/generated/registries";

/**
 * The web boot view (#853): the Septena mark on the app canvas, with a slow
 * pulse (none under prefers-reduced-motion). The static export prerenders
 * SeptenaApp's first state, so this markup is in index.html and paints before
 * the JS loads; React then replaces it with the app or the sign-in screen.
 * Colors are the theme variables in globals.css; styles are `.septena-boot*`.
 */
export function BootSplash({ language = "en" }: { language?: string }) {
  return (
    <main
      className="septena-boot"
      role="status"
      aria-live="polite"
      aria-label={registryText(SIGN_IN.copy.loading, language)}
    >
      <img
        src="/icon.svg"
        alt=""
        width={72}
        height={72}
        draggable={false}
        className="septena-boot-mark"
      />
    </main>
  );
}
