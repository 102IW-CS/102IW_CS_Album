'use strict';
/* Shared by terms.html and privacy.html: theme, contents highlighting, contact email. */
const $ = id => document.getElementById(id);
const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch {} }
};
function icon(id) {
  const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg'), u = document.createElementNS('http://www.w3.org/2000/svg', 'use');
  u.setAttribute('href', '#' + id); s.append(u); return s;
}
// Same theme setting as the album: dark unless light was chosen.
function applyTheme() {
  const t = store.get('photoshare:theme') === 'light' ? 'light' : 'dark';
  document.documentElement.setAttribute('data-theme', t);
  $('themeColor').setAttribute('content', t === 'dark' ? '#1d1c19' : '#f4f2ee');
  const label = t === 'dark' ? 'Switch to light theme' : 'Switch to dark theme';
  $('themeBtn').replaceChildren(icon(t === 'dark' ? 'i-sun' : 'i-moon'));
  $('themeBtn').setAttribute('aria-label', label); $('themeBtn').title = label;
}
applyTheme();
$('themeBtn').onclick = () => { store.set('photoshare:theme', store.get('photoshare:theme') === 'light' ? 'dark' : 'light'); applyTheme(); };

// Contact email, assembled here so simple scrapers reading the page source don't pick it up.
const EMAIL = ['b4anjan', 'gmail.com'].join('@');
document.querySelectorAll('[data-email]').forEach(a => {
  a.href = 'mailto:' + EMAIL + '?subject=' + encodeURIComponent(a.dataset.email || 'Photo Share');
  if (!a.textContent.trim()) a.textContent = EMAIL;
});

// Version list closes when you click elsewhere.
document.addEventListener('click', e => {
  document.querySelectorAll('details.ver[open]').forEach(d => { if (!d.contains(e.target)) d.open = false; });
});

// Contents: open on wide screens, collapsed on phones; highlight the section being read.
const toc = document.querySelector('.toc details');
const wide = matchMedia('(min-width: 921px)');
const syncToc = () => { if (toc) toc.open = wide.matches; };
syncToc(); wide.addEventListener?.('change', syncToc);
const links = [...document.querySelectorAll('.toc a[href^="#"]')];
const byId = new Map(links.map(a => [a.getAttribute('href').slice(1), a]));
const seen = new Set();
const io = new IntersectionObserver(entries => {
  entries.forEach(en => en.isIntersecting ? seen.add(en.target.id) : seen.delete(en.target.id));
  const firstVisible = [...byId.keys()].find(id => seen.has(id));
  links.forEach(a => a.classList.toggle('on', a.getAttribute('href') === '#' + firstVisible));
}, { rootMargin: '-80px 0px -60% 0px' });
byId.forEach((_, id) => { const s = $(id); if (s) io.observe(s); });
links.forEach(a => a.addEventListener('click', () => { if (!wide.matches && toc) toc.open = false; }));
