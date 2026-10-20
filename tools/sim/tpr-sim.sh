#!/bin/bash
# Simulator test bench driver for TopRow. Local only — never touches the phone.
#
#   tpr-sim.sh build            build host app + simulator build of the tweak, install host app
#   tpr-sim.sh launch [tweak]   (re)launch TPRHost, optionally with the tweak injected
#   tpr-sim.sh cmd 'line' ...   run host commands (see host/main.m), print their output
#   tpr-sim.sh shot <name>      screenshot to tools/sim/out/<name>.png
#   tpr-sim.sh pull <file>      print a file from the host app's tmp dir
#   tpr-sim.sh log [secs]       show recent [TopRow]/[TPRHost] log lines
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
UDID="${TPR_UDID:-$(cat "$HERE/.udid")}"   # TPR_UDID picks another simulator
BUNDLE=dev.rtrdd.tprhost
BUILD="$HERE/build"
OUT="$HERE/out"
SIM_TARGET=arm64-apple-ios15.0-simulator
mkdir -p "$BUILD" "$OUT"

simcc() { xcrun -sdk iphonesimulator clang -target "$SIM_TARGET" -fobjc-arc -Wall "$@"; }

boot() {
    if ! xcrun simctl list devices | grep "$UDID" | grep -q Booted; then
        xcrun simctl boot "$UDID"
        xcrun simctl bootstatus "$UDID" >/dev/null
    fi
}

tmpdir() { echo "$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)/tmp"; }

case "${1:-}" in
build)
    boot
    rm -rf "$BUILD/TPRHost.app" && mkdir -p "$BUILD/TPRHost.app"
    simcc -framework UIKit -framework CoreGraphics -o "$BUILD/TPRHost.app/TPRHost" "$HERE/host/main.m"
    cp "$HERE/host/Info.plist" "$BUILD/TPRHost.app/"
    codesign -s - -f "$BUILD/TPRHost.app" >/dev/null 2>&1
    xcrun simctl install "$UDID" "$BUILD/TPRHost.app"
    simcc -dynamiclib -DTPR_SIMULATOR=1 -framework UIKit -framework Foundation -framework CoreGraphics \
        -install_name @rpath/TopRow.dylib -o "$BUILD/TopRow.dylib" "$ROOT"/tweak/*.m
    codesign -s - -f "$BUILD/TopRow.dylib" >/dev/null 2>&1
    # Settings panes (not the AltList one), loaded into TPRHost by its "prefs" command.
    PF="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys;print([r["bundlePath"] for r in json.load(sys.stdin)["runtimes"] if r["version"].startswith("18.4")][0])')/Contents/Resources/RuntimeRoot/System/Library/PrivateFrameworks"
    P="$ROOT/tweak/prefs"
    rm -rf "$BUILD/TopRowPrefs.bundle" "$BUILD/include" && mkdir -p "$BUILD/TopRowPrefs.bundle" "$BUILD/include"
    ln -s "$THEOS/vendor/include/Preferences" "$BUILD/include/Preferences"   # only these: the rest shadows SDK headers
    simcc -bundle -DTPR_SIMULATOR=1 -DTPR_VERSION=\"sim\" -I"$BUILD/include" "$PF/Preferences.framework/Preferences" -framework UIKit -framework CoreGraphics \
        -framework UniformTypeIdentifiers -o "$BUILD/TopRowPrefs.bundle/TopRowPrefs" "$P/TPRPrefsStore.m" "$P/TPRSetups.m" "$P/TPRShareSheet.m" \
        "$P/TPRBaseListController.m" "$P/TPRRootListController.m" "$P/TPRKeysController.m" "$P/TPRKeyboardTypesController.m" \
        "$P/TPRSetupsController.m" "$P/TPRSliderCell.m"
    cp "$P"/Resources/*.plist "$BUILD/TopRowPrefs.bundle/"
    codesign -s - -f "$BUILD/TopRowPrefs.bundle" >/dev/null 2>&1
    echo "built: $BUILD/TPRHost.app $BUILD/TopRow.dylib"
    ;;
launch)
    boot
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    T="$(tmpdir)"; rm -f "$T"/tpr-*.txt
    if [ "${2:-}" = tweak ]; then
        SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$BUILD/TopRow.dylib" SIMCTL_CHILD_TPR_PREFS_BUNDLE="$BUILD/TopRowPrefs.bundle" \
            xcrun simctl launch "$UDID" "$BUNDLE"
    else
        xcrun simctl launch "$UDID" "$BUNDLE"
    fi
    sleep "${TPR_SETTLE:-4}"
    ;;
cmd)
    shift
    T="$(tmpdir)"
    before=$( [ -f "$T/tpr-out.txt" ] && wc -l < "$T/tpr-out.txt" || echo 0 )
    printf '%s\n' "$@" > "$T/tpr-cmd.txt"
    xcrun simctl spawn "$UDID" notifyutil -p dev.rtrdd.tprhost.cmd
    sleep "${TPR_WAIT:-1.5}"
    tail -n +"$((before + 1))" "$T/tpr-out.txt"
    ;;
shot)
    xcrun simctl io "$UDID" screenshot "$OUT/$2.png" >/dev/null 2>&1
    echo "$OUT/$2.png"
    ;;
pull)
    cat "$(tmpdir)/$2"
    ;;
log)
    xcrun simctl spawn "$UDID" log show --last "${2:-60}s" --style compact \
        --predicate 'eventMessage CONTAINS "[TopRow]" OR eventMessage CONTAINS "[TPRHost]"' 2>/dev/null | tail -n 80
    ;;
*)
    sed -n '2,10p' "$0"; exit 1 ;;
esac
