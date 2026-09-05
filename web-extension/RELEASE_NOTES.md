# Zoom Auto Admit Web — Attendance Update

The Chrome/Edge extension now combines automatic Zoom waiting-room admission
with local attendance tracking.

## What's new

- Captures visible Zoom participant names every 15 seconds while attendance is running.
- Supports immediate snapshots with **Capture now**.
- Imports official rosters from pasted text, CSV, or TXT files.
- Keeps the official roster in its original order.
- Shows captured-but-unmatched Zoom names separately.
- Enforces one-to-one matching: one student cannot be marked present under two
  different Zoom identities, and one Zoom identity cannot mark two students present.
- Exports Present, Absent, and Needs Review results as UTF-8 CSV.
- Adds optional OpenRouter matching for unresolved Arabic/English, incomplete,
  or misspelled display names.

## Install or update

1. Download `zoom-auto-admit-web.zip` below.
2. Unzip it to a permanent folder.
3. Open `chrome://extensions` or `edge://extensions`.
4. Enable **Developer mode**.
5. For a new installation, press **Load unpacked** and select the unzipped
   `zoom-auto-admit-web` folder.
6. To update an existing installation without losing locally stored settings or
   attendance, replace the old folder contents while keeping the same folder
   path, then press **Reload** on the extension card.

## Attendance

1. Open the extension and choose **Attendance → Open**.
2. Paste/import one official student name per line.
3. Save the roster, enter a session name, and press **Start attendance**.
4. Keep Zoom's **Participants** panel open. The list updates automatically every
   15 seconds; **Capture now** forces an immediate update.
5. Review uncertain/unmatched names, then export the CSV.

## Optional OpenRouter setup

1. Sign in at <https://openrouter.ai/>.
2. Create a key at <https://openrouter.ai/settings/keys> and give it a small
   spending limit where available.
3. Open the extension's Attendance page, paste the key, and press **Save key**.
4. Use `openrouter/free` as the model for OpenRouter's current free-model router.
5. Press **Match unresolved names with AI** only when local matching leaves names unresolved.

The key is stored in the current browser profile and is sent only to OpenRouter
when AI matching is requested. Use a restricted key and clear it on shared
computers. HTTP `402` usually means the selected model/account cannot serve the
request; check the key/account balance and use `openrouter/free`. HTTP `429`
normally means the free request limit has been reached.

Auto-admit, attendance capture, roster storage, local matching, and CSV export
continue to work without an OpenRouter key.
