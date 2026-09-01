// Zoom Auto Admit (Web) — content script.
//
// Watches the Zoom Web Client DOM for waiting-room admit controls and presses
// them. Zoom ships obfuscated class names, so matching is driven by the visible
// label (aria-label / text / title) instead of any structural selector.

const SETTINGS = {
  enabled: true,
  preferAdmitAll: true,
  debug: false,
  extraAdmitLabels: []
};

const CLICK_COOLDOWN_MS = 3000;
const SCAN_DEBOUNCE_MS = 300;
const SCAN_INTERVAL_MS = 2000;

const lastClickedAt = new WeakMap();
let scanTimer = null;

function normalize(value) {
  return (value || "").replace(/\s+/g, " ").trim().toLowerCase();
}

function labelsOf(element) {
  return [
    element.getAttribute("aria-label"),
    element.getAttribute("title"),
    element.textContent
  ]
    .map(normalize)
    .filter(Boolean);
}

function matchesAny(labels, candidates) {
  return labels.some((label) => candidates.includes(label));
}

function isVisible(element) {
  if (element.disabled) return false;
  if (element.getAttribute("aria-disabled") === "true") return false;
  if (element.getAttribute("aria-hidden") === "true") return false;
  return element.getClientRects().length > 0;
}

function isCoolingDown(element) {
  const previous = lastClickedAt.get(element);
  return previous !== undefined && Date.now() - previous < CLICK_COOLDOWN_MS;
}

function candidateButtons() {
  const nodes = document.querySelectorAll(
    'button, [role="button"], a[role="button"], input[type="button"]'
  );
  return Array.from(nodes).filter(isVisible);
}

function classify(element) {
  const labels = labelsOf(element);
  if (matchesAny(labels, ZAA_LABELS.blocked)) return null;
  if (matchesAny(labels, ZAA_LABELS.admitAll)) return "admitAll";
  const admitLabels = ZAA_LABELS.admit.concat(SETTINGS.extraAdmitLabels);
  if (matchesAny(labels, admitLabels)) return "admit";
  return null;
}

function press(element, kind) {
  lastClickedAt.set(element, Date.now());
  element.click();
  // The counter lives in the service worker: this page runs one content script
  // per frame, and each would otherwise keep its own count.
  chrome.runtime.sendMessage({ type: "admitted" }, () => void chrome.runtime.lastError);
  if (SETTINGS.debug) {
    console.log("[zoom-auto-admit] pressed", kind, labelsOf(element)[0], element);
  }
}

function scan() {
  if (!SETTINGS.enabled) return;

  const buttons = candidateButtons();
  const admitAll = [];
  const admit = [];

  for (const button of buttons) {
    if (isCoolingDown(button)) continue;
    const kind = classify(button);
    if (kind === "admitAll") admitAll.push(button);
    else if (kind === "admit") admit.push(button);
  }

  if (SETTINGS.preferAdmitAll && admitAll.length > 0) {
    press(admitAll[0], "admitAll");
    return;
  }

  for (const button of admit) {
    press(button, "admit");
  }
}

function scheduleScan() {
  if (scanTimer !== null) return;
  scanTimer = setTimeout(() => {
    scanTimer = null;
    scan();
  }, SCAN_DEBOUNCE_MS);
}

function dumpButtons() {
  const rows = candidateButtons().map((button) => ({
    label: labelsOf(button)[0] || "",
    text: normalize(button.textContent).slice(0, 60),
    aria: button.getAttribute("aria-label") || "",
    classes: button.className || "",
    match: classify(button) || "-"
  }));
  console.table(rows);
  console.log("[zoom-auto-admit] frame:", location.href, "buttons:", rows.length);
}

chrome.storage.local.get(SETTINGS, (stored) => {
  Object.assign(SETTINGS, stored);
  scan();
});

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "local") return;
  for (const [key, change] of Object.entries(changes)) {
    if (key in SETTINGS) SETTINGS[key] = change.newValue;
  }
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "dump") {
    dumpButtons();
    sendResponse({ ok: true, url: location.href });
  }
  if (message?.type === "ping") {
    sendResponse({ ok: true, top: window === window.top });
  }
  return false;
});

new MutationObserver(scheduleScan).observe(document.documentElement, {
  childList: true,
  subtree: true
});

setInterval(scan, SCAN_INTERVAL_MS);
