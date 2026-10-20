/* Precache workshop pages once; cached navigation does not poll the network. */
(function () {
  function status(state) { document.documentElement.dataset.offlineState = state; }
  if (!("serviceWorker" in navigator) || !window.isSecureContext || location.protocol === "file:") {
    status("unavailable");
    return;
  }
  // A newly activated release must replace HTML served by the former cache.
  // First-time installation needs no reload; only pages already controlled do.
  const hadController = Boolean(navigator.serviceWorker.controller);
  let reloading = false;
  function query(worker) { if (worker) worker.postMessage({ type: "CACHE_STATUS" }); }
  navigator.serviceWorker.addEventListener("message", function (event) {
    if (event.data && event.data.type === "CACHE_READY") status("ready");
    if (event.data && event.data.type === "RELEASE_NAVIGATION") {
      reloading = true;
      if (event.ports && event.ports[0]) event.ports[0].postMessage("ready");
    }
  });
  navigator.serviceWorker.register("sw.js", { updateViaCache: "none" }).then(function (registration) {
    query(registration.active);
    navigator.serviceWorker.ready.then(function (ready) { query(ready.active); });
    const check = function () {
      const worker = registration.installing;
      if (!worker) return;
      worker.addEventListener("statechange", function () {
        if (worker.state === "activated") query(worker);
        if (worker.state === "redundant") status("unavailable");
      });
    };
    registration.addEventListener("updatefound", check); check();
  }).catch(function () { status("unavailable"); });
  navigator.serviceWorker.addEventListener("controllerchange", function () {
    if (hadController && !reloading) {
      reloading = true;
      location.reload();
      return;
    }
    query(navigator.serviceWorker.controller);
  });
})();
