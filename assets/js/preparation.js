/* Checklist confirmations are self-reported; opening a link never verifies sign-in. */
(function () {
  const KEY = "magnet-workshop-preparation-v1";
  const keys = ["colab", "google", "agent"];
  let state = {};
  try { state = JSON.parse(localStorage.getItem(KEY) || "{}") || {}; } catch (error) { /* Checklist remains usable. */ }
  function render() {
    let count = 1;
    keys.forEach(function (key) {
      const complete = state[key] === true;
      document.getElementById("prep-" + key).checked = complete;
      document.getElementById("setup-" + key).classList.toggle("is-complete", complete);
      if (complete) count += 1;
    });
    document.getElementById("prep-progress").textContent = count + " of 4 preparations complete" + (count === 4 ? " · Ready for the full workshop" : "");
  }
  keys.forEach(function (key) {
    document.getElementById("prep-" + key).addEventListener("change", function () {
      state[key] = this.checked;
      try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (error) { /* Keep current-tab state. */ }
      render();
    });
  });
  render();
})();
