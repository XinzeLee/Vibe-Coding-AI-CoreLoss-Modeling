/* Bump VERSION whenever a cached workshop file changes before deployment. */
const VERSION = "workshop-stage1-2026-10-14-v3";
const BASE = new URL("./", self.location.href);
const CACHE = "vibe-pe-" + BASE.pathname + "-" + VERSION;
const FILES = [
  "./", "index.html", "overview.html", "lab.html", "quiz.html", "badge.html",
  "assets/css/app.css", "assets/js/preparation.js", "assets/js/likes.js", "assets/js/offline.js",
  "assets/img/core-loss-preview.webp", "assets/img/howto-strip.webp", "assets/img/apec-2027-original.png"
];
const URLS = FILES.map(path => new URL(path, BASE).href);
self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(URLS)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    const previous = keys.filter(key => key.startsWith("vibe-pe-" + BASE.pathname + "-") && key !== CACHE);
    await Promise.all(previous.map(key => caches.delete(key)));
    const windows = previous.length ? (await self.clients.matchAll({ type: "window", includeUncontrolled: true })).filter(client => {
      const url = new URL(client.url);
      return url.origin === BASE.origin && url.pathname.startsWith(BASE.pathname);
    }) : [];
    // Older saved pages cannot respond; a short timeout still refreshes them.
    // New pages acknowledge this message and suppress their fallback reload.
    await Promise.all(windows.map(client => new Promise(resolve => {
      const channel = new MessageChannel();
      const timer = setTimeout(finish, 300);
      function finish() { clearTimeout(timer); channel.port1.close(); resolve(); }
      channel.port1.onmessage = finish;
      client.postMessage({ type: "RELEASE_NAVIGATION" }, [channel.port2]);
    })));
    await self.clients.claim();
    // Navigation fetches can wait for activation to finish. Dispatch them
    // without awaiting their completion inside this activation event.
    windows.forEach(client => { client.navigate(client.url).catch(() => null); });
  })());
});
self.addEventListener("message", event => {
  if (event.data?.type === "CACHE_STATUS") event.waitUntil(caches.open(CACHE).then(cache => Promise.all(URLS.map(url => cache.match(url)))).then(entries => {
    if (entries.every(Boolean)) event.source?.postMessage({ type: "CACHE_READY" });
  }));
});
self.addEventListener("fetch", event => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET" || url.origin !== BASE.origin || !url.pathname.startsWith(BASE.pathname)) return;
  const normalized = new URL(url.href); normalized.hash = ""; normalized.search = "";
  // Cache only the known workshop files. APIs and arbitrary documents bypass this cache.
  if (!URLS.includes(normalized.href)) return;
  event.respondWith(caches.open(CACHE).then(async cache => {
    const cached = await cache.match(normalized.href);
    if (cached) return cached;
    const response = await fetch(event.request);
    if (response.ok) await cache.put(normalized.href, response.clone());
    return response;
  }));
});
