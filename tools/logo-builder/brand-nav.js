// Shared sticky navigation bar for all Septena Brand Study & Generator workpages.
// Automatically displays the currently selected Septena icon + brand palette across every page.
(function () {
  const script = document.currentScript;
  if (!script) return;
  const active = script.dataset.active || '';
  const root = (script.dataset.root || '.').replace(/\/$/, '');

  const items = [
    { id: 'competitors', label: '39 Competitors', href: `${root}/competitor-gallery/index.html` },
    { id: 'language', label: 'Language Gallery', href: `${root}/language-gallery/index.html` },
    { id: 'backgrounds', label: 'Background Generator', href: `${root}/backgrounds.html` },
    { id: 'appstore', label: 'App Store Viz ↗', href: `${root}/../../appstore/viz/index.html` },
  ];

  const style = document.createElement('style');
  style.textContent = `
    #septena-brand-nav {
      position: sticky; top: 0; z-index: 9999;
      display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between;
      gap: 10px; padding: 8px 20px;
      background: rgba(255, 255, 255, 0.90);
      backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px);
      border-bottom: 1px solid rgba(24, 28, 34, 0.12);
      font: 500 12px/1.2 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
      color: #181c22;
    }
    @media (prefers-color-scheme: dark) {
      #septena-brand-nav {
        background: rgba(17, 19, 23, 0.90);
        border-bottom-color: rgba(255, 255, 255, 0.12);
        color: #f1f4f8;
      }
    }
    #septena-brand-nav .sbn-left { display: flex; align-items: center; gap: 10px; }
    #septena-brand-nav .sbn-icon { width: 24px; height: 24px; flex: 0 0 auto; border-radius: 5.5px; overflow: hidden; box-shadow: 0 2px 6px rgba(0,0,0,0.22); }
    #septena-brand-nav .sbn-brand { font-weight: 700; letter-spacing: -0.01em; white-space: nowrap; }
    #septena-brand-nav .sbn-pill {
      font: 500 11px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
      padding: 4px 8px; border-radius: 999px;
      background: rgba(128, 128, 128, 0.13);
      opacity: 0.85; white-space: nowrap;
    }
    #septena-brand-nav .sbn-links { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; }
    #septena-brand-nav a {
      text-decoration: none; color: inherit; opacity: 0.72;
      padding: 6px 10px; border-radius: 8px; font-weight: 600;
      transition: opacity 120ms ease, background 120ms ease;
    }
    #septena-brand-nav a:hover { opacity: 1; background: rgba(128, 128, 128, 0.14); }
    #septena-brand-nav a.sbn-active { opacity: 1; background: #181c22; color: #ffffff; }
    @media (prefers-color-scheme: dark) {
      #septena-brand-nav a.sbn-active { background: #f1f4f8; color: #111317; }
    }
  `;
  document.head.appendChild(style);

  const nav = document.createElement('nav');
  nav.id = 'septena-brand-nav';
  nav.setAttribute('aria-label', 'Septena Brand Studio Navigation');
  nav.innerHTML = `
    <div class="sbn-left">
      <div id="sbn-live-icon" class="sbn-icon"></div>
      <span class="sbn-brand">Septena Brand Studio</span>
      <span id="sbn-live-pill" class="sbn-pill">Septena Compass · Jabuticaba</span>
    </div>
    <div class="sbn-links">
      ${items.map((it) => `<a href="${it.href}" class="${it.id === active ? 'sbn-active' : ''}">${it.label}</a>`).join('')}
    </div>
  `;

  function updateLiveBadge() {
    if (!window.SeptenaBrand) return;
    const sb = window.SeptenaBrand;
    const st = sb.loadState();
    const prop = sb.findProposal ? sb.findProposal(st.activeProposal) : (sb.PROPOSALS.find((p) => p.id === st.activeProposal) || sb.PROPOSALS[0]);
    const pal = sb.resolvePalette(st, prop);
    const iconEl = document.getElementById('sbn-live-icon');
    const pillEl = document.getElementById('sbn-live-pill');
    if (iconEl) iconEl.innerHTML = sb.renderProposalSVG(prop.id, pal, { size: '100%', idPrefix: 'nav_ico' });
    if (pillEl) pillEl.textContent = `${prop.shortName} · ${pal.name}`;
  }

  function mount() {
    if (document.body.firstChild) document.body.insertBefore(nav, document.body.firstChild);
    else document.body.appendChild(nav);

    if (window.SeptenaBrand) {
      updateLiveBadge();
    } else {
      const s = document.createElement('script');
      s.src = `${root}/brand-state.js`;
      s.onload = updateLiveBadge;
      document.head.appendChild(s);
    }
    window.addEventListener('septena-brand-change', updateLiveBadge);
    window.addEventListener('storage', updateLiveBadge);
  }

  if (document.body) mount();
  else document.addEventListener('DOMContentLoaded', mount);
})();
