# Zoom Auto Admit — Web

A Chrome / Edge extension that **automatically admits people from the Zoom
waiting room** when you host a meeting in the browser (the Zoom Web Client at
`app.zoom.us`). No more clicking **Admit** for every latecomer.

It works entirely inside your own browser — no Zoom account connection, no
sign-in, no server, nothing leaves your machine.

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

Everything runs locally in your browser. The extension has access only to
`*.zoom.us` pages, stores only your on/off settings and the admitted count in
the browser, and sends nothing anywhere.

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
| `background.js` | Owns the admitted counter and the toolbar badge |
| `popup.html/.css/.js` | Toolbar UI |
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
