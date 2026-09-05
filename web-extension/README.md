# Zoom Auto Admit — Web

A Chrome / Edge extension that **automatically admits people from the Zoom
waiting room** when you host a meeting in the browser (the Zoom Web Client at
`app.zoom.us`). No more clicking **Admit** for every latecomer.

It works without a Zoom account connection, sign-in, or application server.
Auto-admit and local attendance matching stay in your browser. If you explicitly
run optional AI matching, only the unresolved roster and Zoom names are sent to
OpenRouter using your own API key.

> Companion to the macOS **Zoom Auto Admit** app in this repository, which does
> the same thing for the native Zoom desktop client.

## What it does

- Watches the meeting page and presses **Admit** / **Admit all** as people
  arrive in the waiting room.
- Prefers **Admit all** (one click for everyone) when it is on screen.
- Never presses **Deny** or **Remove** — only admit controls.
- Shows a running count of how many people it let in, on the toolbar icon and in
  the popup.
- Works in several languages (English, Arabic, Spanish, French, German).
- Records attendance from the open Participants panel every 15 seconds.
- Imports a class roster, matches Zoom display names locally, and flags uncertain matches for review.
- Can use an optional OpenRouter API key for unresolved Arabic/English or misspelled names.
- Exports present, absent, and needs-review results as a UTF-8 CSV file.
- Preserves the exact roster order and lists captured-but-unmatched Zoom names separately.
- Enforces one-to-one attendance: one student cannot be matched to two Zoom identities, and one Zoom identity cannot mark two students present.

## Install (takes a minute)

The extension is distributed as a `.zip` — it is **not** on the Chrome Web
Store, so you load it yourself. This is safe and normal for tools shared
directly.

1. **Download** `zoom-auto-admit-web.zip` from the
   [latest release](../../releases/latest).
2. **Unzip** it. You get a folder named `zoom-auto-admit-web`.
3. Open your browser and go to:
   - Chrome: `chrome://extensions`
   - Edge: `edge://extensions`
4. Turn on **Developer mode** (toggle, top-right in Chrome / left side in Edge).
5. Click **Load unpacked** and pick the **unzipped folder**.
6. Done — the gate icon appears in your toolbar.

> Keep the unzipped folder somewhere permanent (not in Downloads / Trash). The
> browser loads it from that location every time it starts.

## How to use it

1. Start or join your meeting **as host or co-host** in the browser at
   `https://app.zoom.us/wc/...`.
2. Open the **Participants** panel (so the waiting-room controls exist on the
   page).
3. That's it. When someone lands in the waiting room, they're admitted within a
   couple of seconds.

Click the toolbar icon any time to pause it, switch off **Admit all**, or see
how many people it has admitted. Leave the meeting tab open — it only works
while that tab is running.

### Record attendance

1. Click the extension icon and choose **Attendance → Open**.
2. Paste one official student name per line, or import a CSV/TXT roster.
3. Enter a session name and click **Start attendance**.
4. Keep Zoom's **Participants** panel open. The extension records unique names
   every 15 seconds; **Capture now** takes an immediate snapshot.
5. Review the matches and click **Export CSV** when finished.

Local name matching does not need an account. For harder cases, paste an
OpenRouter key in the Attendance screen and select a model. The key is stored
in `chrome.storage.local` on that browser profile and is sent only to
OpenRouter when you click the AI matching button. Browser extension storage is
not a password vault, so use a restricted/low-limit key and clear it when this
is a shared computer.

### Set up OpenRouter (optional)

1. Sign in at <https://openrouter.ai/>.
2. Open <https://openrouter.ai/settings/keys> and create a new API key. Give it a
   small credit limit when the account offers that option.
3. In the extension, open **Attendance**, paste the key, and press **Save key**.
   A saved key is shown by its final four characters; it is never committed to
   this repository.
4. Enter `openrouter/free` in **Model** to let OpenRouter choose a currently
   available free model, then press **Match unresolved names with AI**.

Free-model availability and rate limits can change. If matching reports HTTP
`402`, confirm the key is active, the account balance is not negative, and the
model is `openrouter/free`. HTTP `429` normally means the free request limit was
reached; wait and retry later. AI matching is optional—the extension continues
capturing attendance and applying local exact/normalized matches without it.

## Requirements

- Google Chrome or Microsoft Edge (any recent version).
- You must be the **host or co-host** — only hosts can admit people.
- You must be using **Zoom in the browser**, not the desktop app. (For the
  desktop app, use the macOS app in this repository instead.)

## If nobody gets admitted

Zoom sometimes renames or translates its buttons, which can stop the matching.
To check what your Zoom shows:

1. Click the extension icon → turn on **Console logging** → click **Dump buttons
   to console**.
2. Open the browser DevTools (`View → Developer → Developer Tools`) on the Zoom
   tab and read the table it prints — it lists every button and whether the
   extension recognised it.
3. Send that list to whoever maintains the extension so the label can be added.

## Privacy

Auto-admit, participant capture, roster storage, local matching, and CSV export
run locally in your browser. The extension can access `*.zoom.us` and
`openrouter.ai`; it contacts OpenRouter only after you save a key and click
**Match unresolved names with AI**. That request contains only unresolved
official names and unmatched Zoom display names. Your key and attendance data
are stored in the current browser profile and are never placed in the source.

## Trouble & limits

- **The meeting tab must stay open.** Close it and admitting stops.
- **Zoom's web UI changes without notice**; a Zoom update can temporarily break
  matching until the labels are updated.
- If **Developer mode** extensions get disabled on browser restart, just toggle
  Developer mode back on and reload.

---

## For developers

The shipped `.zip` is built from source in this folder. The source is plain and
readable; the release build is obfuscated.

| File | Role |
| --- | --- |
| `manifest.json` | MV3 manifest — matches, icons, service worker |
| `labels.js` | Button labels to press, per language, plus a blocked list |
| `content.js` | DOM watcher and press logic, injected into every frame |
| `background.js` | Owns the admitted counter, toolbar badge, and attendance snapshots |
| `popup.html/.css/.js` | Toolbar UI |
| `attendance.html/.css/.js` | Roster, capture, matching, OpenRouter, review, and CSV export UI |
| `icons/` | `icon.svg` (48/128) and `icon-small.svg` (16/32) + rendered PNGs |
| `build.mjs` | Produces the obfuscated `dist/` build |

### Run from source

Load this folder directly with **Load unpacked** — no build needed. Matching is
driven by the **visible label** (`aria-label` / text / title), because Zoom's
class names are obfuscated and change between releases. Comparison is exact
after case/whitespace normalization, so a button reading "Admit" is pressed
while "Admit participants automatically" in a settings dialog is not. Labels in
`ZAA_LABELS.blocked` (Deny, Remove, …) are never pressed. Each element gets a
3-second cooldown after a press.

The admitted counter lives in `background.js`, not the content script: Zoom's
page runs the content script in several frames at once, and each would otherwise
keep — and overwrite — its own count.

### Build the distributable copy

```sh
npm install   # once, pulls javascript-obfuscator
npm run build # writes obfuscated dist/
```

Load `web-extension/dist` with **Load unpacked**, or zip it for distribution.
The build renames identifiers, encodes strings, flattens control flow, adds
self-defending / debug-protection guards, and merges `labels.js` into
`content.js`.

**Obfuscation is not encryption.** An extension always ships as executable text,
so a determined reader can still recover behaviour. This raises the effort to
read or edit the code; it does not make it private. Never put secrets (API keys,
tokens) in the extension expecting them to stay hidden.

### Adjusting labels

Add the label you see in the DevTools dump to `ZAA_LABELS.admit` or
`ZAA_LABELS.admitAll` in `labels.js`, then rebuild. If the dump is empty, the
meeting UI is in a cross-origin iframe the content script can't reach — add that
origin to `host_permissions` and `matches` in `manifest.json`.

### Icons

`icons/icon.svg` is used at 48/128 px; `icon-small.svg` is a reduced version
that still reads at 16/32 px. Re-render after an edit:

```sh
rsvg-convert -w 128 -h 128 icons/icon.svg       -o icons/icon128.png
rsvg-convert -w 48  -h 48  icons/icon.svg       -o icons/icon48.png
rsvg-convert -w 32  -h 32  icons/icon-small.svg -o icons/icon32.png
rsvg-convert -w 16  -h 16  icons/icon-small.svg -o icons/icon16.png
```

---

Powered by [Mohamed Hosam](https://mohamed.hosam.quantara-eg.com/)
