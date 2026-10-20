/* Shared counts use the Cloudflare Worker. Poll only visible counters while online. */
(function (global) {
  const PREFIX = "vibe-pe-community-v2-";
  const memory = {};
  function read(key, session) { try { return (session ? sessionStorage : localStorage).getItem(PREFIX + key) || memory[key]; } catch (err) { return memory[key]; } }
  function write(key, value, session) { memory[key] = String(value); try { (session ? sessionStorage : localStorage).setItem(PREFIX + key, String(value)); } catch (err) { /* Counters must not block the workshop. */ } }
  function token() { return global.crypto && crypto.randomUUID ? crypto.randomUUID() : Date.now().toString(36) + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2); }
  function identity(key, session) { const saved = read(key, session); if (saved) return saved; const id = token(); write(key, id, session); return id; }
  const api = global.LAB ? LAB.counterApi : "https://xinzelee-counter.xinzelee.workers.dev/workshop/v1/";
  let counts = null, live = false, busy = false, visible = false, timer = null, lastRead = 0, stopped = false;
  try { counts = JSON.parse(read("counts") || "null"); } catch (err) { /* No previous shared count. */ }
  function valid(data) { return data && Number.isSafeInteger(data.visits) && data.visits >= 0 && Number.isSafeInteger(data.likes) && data.likes >= 0; }
  if (!valid(counts)) counts = null;
  const liked = function () { return read("liked") === "1"; };
  function paint() {
    document.querySelectorAll("[data-visit-count]").forEach(function (el) { el.textContent = counts ? counts.visits.toLocaleString() + " visits" + (live ? "" : " (saved)") : "Visits unavailable"; });
    document.querySelectorAll("[data-like-count]").forEach(function (el) { el.textContent = counts ? counts.likes.toLocaleString() + " likes" + (live ? "" : " (saved)") : "Likes unavailable"; });
    document.querySelectorAll("[data-like-btn]").forEach(function (el) { el.disabled = busy || liked(); el.textContent = busy ? "Saving like…" : liked() ? "Liked" : "Like this workshop"; el.setAttribute("aria-pressed", String(liked())); });
    document.querySelectorAll("[data-counter-status]").forEach(function (el) {
      el.textContent = read("pending-like") ? "Your like is saved on this device and will sync when connected." : "";
      el.hidden = !el.textContent;
    });
  }
  async function request(path, body) {
    if (!navigator.onLine || location.protocol === "file:") throw new Error("Offline");
    const controller = new AbortController();
    const timeout = setTimeout(function () { controller.abort(); }, 4000);
    try {
      const response = await fetch(new URL(path, api).href, {
        method: body ? "POST" : "GET", cache: "no-store", signal: controller.signal,
        headers: body ? { "Content-Type": "application/json" } : {},
        body: body ? JSON.stringify(body) : undefined
      });
      if (!response.ok) throw new Error("Counter unavailable");
      const data = await response.json();
      if (!valid(data)) throw new Error("Invalid counter response");
      counts = data; live = true; stopped = false; lastRead = Date.now(); write("counts", JSON.stringify(data));
      return data;
    } finally { clearTimeout(timeout); }
  }
  function fail() { live = false; stopped = true; clearTimeout(timer); paint(); }
  async function syncLike() {
    const pending = read("pending-like");
    if (!pending || busy) return;
    busy = true; paint();
    try { await request("like", { token: pending }); write("pending-like", ""); }
    catch (err) { fail(); }
    finally { busy = false; paint(); schedule(); }
  }
  async function refresh(force) {
    if (!force && (stopped || busy || Date.now() - lastRead < 55000)) return;
    try { await request("counts"); paint(); }
    catch (err) { fail(); }
    schedule();
  }
  function schedule() {
    clearTimeout(timer);
    const saveData = navigator.connection && navigator.connection.saveData;
    if (visible && !document.hidden && navigator.onLine && !stopped && !saveData) timer = setTimeout(function () { refresh(false); }, 60000);
  }
  async function start() {
    try {
      if (!read("visited", true)) {
        await request("visit", { token: identity("visit-token", true) }); write("visited", "1", true);
      } else {
        const cachedAt = Number(read("read-at") || 0);
        if (!counts || Date.now() - cachedAt >= 60000) await request("counts");
      }
      if (live) write("read-at", String(Date.now()));
      paint();
    } catch (err) { fail(); }
    await syncLike(); schedule();
  }
  document.querySelectorAll("[data-like-btn]").forEach(function (button) {
    button.addEventListener("click", function () {
      if (liked() || busy) return;
      write("liked", "1"); write("pending-like", identity("like-token")); paint(); syncLike();
    });
  });
  if ("IntersectionObserver" in global) {
    const inView = new Set();
    const observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) { if (entry.isIntersecting) inView.add(entry.target); else inView.delete(entry.target); });
      visible = inView.size > 0; schedule();
    });
    document.querySelectorAll("[data-community]").forEach(function (root) { observer.observe(root); });
  } else { visible = true; }
  document.addEventListener("visibilitychange", schedule);
  global.addEventListener("offline", function () { fail(); });
  global.addEventListener("online", function () { stopped = false; start(); });
  global.addEventListener("storage", function () { paint(); });
  global.LabLikes = { hasLiked: liked, refresh: function () { return refresh(true); } };
  paint(); start();
})(window);
