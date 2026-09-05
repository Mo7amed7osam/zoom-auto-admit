// Owns the admitted counter and the toolbar badge.
//
// Every frame of a Zoom page runs its own content script, so the counter cannot
// live there — concurrent frames would clobber each other's writes. Increments
// are funnelled through this worker and serialized on a promise chain.

const BADGE_COLOR = "#2563EB";

let writes = Promise.resolve();

async function paintBadge(count) {
  await chrome.action.setBadgeBackgroundColor({ color: BADGE_COLOR });
  await chrome.action.setBadgeText({ text: count > 0 ? String(Math.min(count, 999)) : "" });
}

function bumpCount() {
  writes = writes.then(async () => {
    const { admittedCount = 0 } = await chrome.storage.local.get("admittedCount");
    const next = admittedCount + 1;
    await chrome.storage.local.set({ admittedCount: next });
    await paintBadge(next);
  });
  return writes;
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "admitted") {
    bumpCount().then(() => sendResponse({ ok: true }));
    return true;
  }
  if (message?.type === "attendanceSnapshot") {
    writes = writes.then(() => mergeAttendanceSnapshot(message));
    writes.then(() => sendResponse({ ok: true }));
    return true;
  }
  return false;
});

async function mergeAttendanceSnapshot(message) {
  const { attendanceSession } = await chrome.storage.local.get("attendanceSession");
  if (!attendanceSession?.active) return;
  const observed = { ...(attendanceSession.observed || {}) };
  for (const rawName of message.names || []) {
    const name = String(rawName || "").trim();
    if (!name) continue;
    const key = name.toLocaleLowerCase();
    const prior = observed[key];
    observed[key] = {
      name: prior?.name || name,
      firstSeenAt: prior?.firstSeenAt || message.capturedAt,
      lastSeenAt: message.capturedAt,
      sightings: (prior?.sightings || 0) + 1
    };
  }
  await chrome.storage.local.set({
    attendanceSession: {
      ...attendanceSession,
      observed,
      snapshots: (attendanceSession.snapshots || 0) + 1,
      lastCapturedAt: message.capturedAt
    }
  });
}

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.admittedCount) {
    paintBadge(changes.admittedCount.newValue || 0);
  }
});

chrome.runtime.onStartup.addListener(async () => {
  const { admittedCount = 0 } = await chrome.storage.local.get("admittedCount");
  paintBadge(admittedCount);
});
