#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"

if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
    print -u2 "Usage: $0 [release|debug]"
    exit 64
fi

cd "$project_root"

# Auto Admit monitoring must never bring Zoom forward.
#
# Two files are allowed to activate Zoom and are excluded by name: the scheduled
# startup workflow's automation (opening Zoom's account menu and starting a
# meeting genuinely need the foreground) and the schedules editor window (the
# user opened it). Everything on the monitoring path must stay focus-free.
# The rule is specifically about bringing *Zoom* forward. Activating this app's
# own windows (NSApp.activate) and AutoLayout's NSLayoutConstraint.activate are
# unrelated and are excluded.
forbidden_in_app='NSRunningApplication|runningApplication.*\.activate\(|application\.activate\(|setFrontmost|kAXRaiseAction|kAXFrontmostAttribute|\.unhide\(\)|CGEventPost'
activation_allowlist='Sources/ZoomAutoAdmitCore/Workflow/LiveZoomAutomation.swift|Sources/ZoomAutoAdmitApp/PreJoinCapture.swift'
if grep -rnE "$forbidden_in_app" Sources/ZoomAutoAdmitApp Sources/ZoomAutoAdmitCore \
    | grep -vE "$activation_allowlist" \
    | grep -v "^\s*//" \
    | grep -v "never" ; then
    print -u2 "ERROR: focus-stealing calls found outside the scheduled-startup allowlist (listed above)."
    exit 65
fi

swift build -c "$configuration" --product ZoomAutoAdmitApp
binary_directory="$(swift build -c "$configuration" --show-bin-path)"

output_directory="$project_root/dist"
app_bundle="$output_directory/Zoom Auto Admit.app"
contents_directory="$app_bundle/Contents"
macos_directory="$contents_directory/MacOS"
resources_directory="$contents_directory/Resources"

if [[ -e "$app_bundle" ]]; then
    rm -rf "$app_bundle"
fi
mkdir -p "$macos_directory" "$resources_directory"
cp "$binary_directory/ZoomAutoAdmitApp" "$macos_directory/ZoomAutoAdmitApp"
cp "$project_root/AppBundle/Info.plist" "$contents_directory/Info.plist"
cp "$project_root/AppBundle/Resources/AppIcon.icns" "$resources_directory/AppIcon.icns"
chmod 755 "$macos_directory/ZoomAutoAdmitApp"

plutil -lint "$contents_directory/Info.plist"

signing_identity="${ZOOM_AUTO_ADMIT_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    signing_identity="$(print -r -- "$signing_identities" | awk -F'"' '/"Developer ID Application:/{print $2; exit}')"
    if [[ -z "$signing_identity" ]]; then
        signing_identity="$(print -r -- "$signing_identities" | awk -F'"' '/"Apple Development:/{print $2; exit}')"
    fi
fi

if [[ -n "$signing_identity" ]]; then
    print "Signing identity: $signing_identity"
    codesign --force --deep --sign "$signing_identity" --timestamp=none "$app_bundle"
else
    print -u2 "WARNING: No stable code-signing identity found; using ad-hoc signing."
    print -u2 "Accessibility permission may need to be removed and re-added after each rebuild."
    codesign --force --deep --sign - --timestamp=none "$app_bundle"
fi
codesign --verify --deep --strict "$app_bundle"

print "$app_bundle"
