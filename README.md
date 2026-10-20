# TopRow

A number row for the stock iOS keyboard, and every other key your way. Free, open source, and adjustable without a respring.

- **Letters:** `1 2 3 4 5 6 7 8 9 0`
- **Shift / Caps Lock:** `! @ # $ % ^ & * ( )`
- **123 and #+=:** an extra `! @ # $ % ^ & * ( )` row under the digits

<p>
  <img src="screenshots/1.jpg" width="160" alt="Custom keys under the number row">
  <img src="screenshots/2.jpg" width="160" alt="Keys page">
  <img src="screenshots/3.jpg" width="160" alt="Setups page">
  <img src="screenshots/4.jpg" width="160" alt="Number row on the keyboard">
  <img src="screenshots/5.jpg" width="160" alt="Shift and Caps Lock symbol row">
  <img src="screenshots/6.jpg" width="160" alt="123 keyboard with the extra symbol row">
  <img src="screenshots/7.jpg" width="160" alt="TopRow settings">
  <img src="screenshots/8.jpg" width="160" alt="Key Height and Bottom Area sliders">
</p>

## Features

- **Top row:** edit it per keyboard page, 1–10 keys, up to 8 characters per key
- **Keys page:** change any key on the letters, Shift / Caps Lock, 123 and #+= pages. Add, remove, reorder or retype keys (up to 12 per row); keys kept from Apple's row keep their accents and localized currency signs
- **Setups:** save your settings under a name, switch between them, and share them as text or a file; automatic backups before resets and before applying a setup
- Keep the digit row while the keyboard is only auto-capitalized
- Symbol hints in the corner of each number key
- Key Height (80–130%) and Bottom Area (60–130%) sliders
- Landscape on/off, with optional separate landscape rows
- Custom labels for the 123, ABC and #+= keys
- Per-app exclusion (AltList) and per-keyboard-type control (email, web, Twitter)
- Works in password fields, share sheets and password managers' AutoFill sheets; number, phone and passcode pads stay stock
- Every setting applies live; preview fields sit right in the settings pages
- **Share Diagnostics** exports a plain-text report for bug reports

## Install

Add **https://dev.rtrdd.fyi** to Sileo or Zebra and install **TopRow**, or download the `.deb` from [Releases](https://github.com/aayy-dev/TopRow/releases).

Requirements: iPhone on a rootless jailbreak, iOS 15 or later. Tested on iOS 26.0, 17.3.1 and 16.2 with Dopamine (and the iOS 18.4, 26.3, 26.5 and 27.0 simulators); reports from other versions are welcome. Depends on PreferenceLoader and AltList. Does nothing on iPad. Uninstall any other number-row tweak first; two of them on the same keyboard will clash.

### iOS 26

iOS 26 builds the iPhone keyboard a new way, and TopRow 2.1 supports it: the row, the Keys page, Symbol Hints, Key Height, Bottom Area, labels, the keyboard-type switches and the landscape settings all work as on earlier iOS. On iOS 26 the row also comes to other letter layouts (German, French, Spanish, Russian, Greek, Arabic and more). A few things differ:

- All pages of a keyboard share one height. A page whose row you leave empty (say, no extra row on 123) gets an empty band at the top instead of a shorter keyboard, so its keys keep Apple's size.
- The email and web-address keyboards share the main keyboard's 123 and #+= pages, so those pages take your Keys page rows too.
- The name-and-phone-number keyboard stays stock.
- Keyboards without a letters page (Hebrew, Thai, Korean, Chinese) stay stock, as before.
- iOS 16.1–18 already build a few minority layouts (Hausa, Yoruba, Sami and others) this new way; on those versions they stay stock, as in TopRow 2.0.

## Build

GitHub Actions builds every push on a macOS runner and publishes a release for each `v*` tag (see `.github/workflows/build.yml`). To build locally you need [Theos](https://theos.dev) and [AltList](https://github.com/opa334/AltList) (extract `AltList.framework` from the `com.opa334.altlist` package on https://opa334.github.io into `$THEOS/lib/iphone/rootless/`, as the workflow does).

```sh
cd tweak
make package FINALPACKAGE=1
```

The package lands in `tweak/packages/`. The Makefile targets the iOS 17.3.1 SDK (the workflow downloads it from [xybp888/iOS-SDKs](https://github.com/xybp888/iOS-SDKs)); to build with another, pass `TARGET=iphone:clang:<sdk>:15.0`. `make do` installs over SSH using `THEOS_DEVICE_IP` and `THEOS_DEVICE_PORT`.

## How it works

UIKit builds each keyboard from a tree of `UIKBTree` nodes that it gets from `-[TUIKBGraphSerialization keyboardForName:]`. TopRow hooks that method and returns a patched deep copy of the tree:

1. Every keyplane (lowercase, shifted, 123, #+=) is copied, and the extra row's keys are merged into an existing row. Everything below moves down one row pitch, keeping Apple's key sizes and gaps.
2. Keys copy their geometry from the row they sit over, or are spread evenly when the row has a different key count.
3. UIKit caches rendered keyplane images by keyset and geometry-set names, not by labels. The settings fingerprint is therefore folded into those names, so a changed row never reuses stale artwork.
4. The Keys page replaces whole rows in the same copies. A row is only replaced on the US QWERTY layout (all of a plane's rows must match Apple's), so other languages and the email and URL number pages keep theirs. Keys left in a row stay Apple's own key objects; new ones are plain keys, sized like Apple's while they fit and narrower when they don't.
5. A Darwin notification from the settings pane reloads the configuration and rebuilds the keyboard in place.

The rest is small hooks: `UIKeyboardLayoutStar` for the auto-capitalization option and the 123/ABC/#+= labels, `UIKBKeyplaneView` for symbol hints, and `UIKeyboardDockView` for the Bottom Area slider.

**iOS 26.** Its iPhone keyboards are "dynamic" trees (`KBdynamic`): no geometry at all. TextInputUI's `TUIKeyplaneView` lays them out with Auto Layout, from rows listed in each key layout's default row set and key widths given in relative units. There TopRow inserts its row as a new row in that set, with an empty attribute entry to match and widths that fill the units of Apple's first row. It grows the keyboard through `+[TUIKeyplane sizeFromScreenTraits:layout:layoutClass:]` (renamed in iOS 27; both are hooked), and puts symbol hints on each key's `TUIKBKeyView`. The same tree serves both orientations, so when landscape is set to differ, the landscape copy gets its own cache key.

TopRow's filter loads it into anything with UIKit loaded, and tweak filters can't exclude processes. So the constructor checks that it's running in an app's own executable (not a helper tool next to it, or a daemon packaged as an app) or in an allowed extension, and returns at once otherwise.

| File | What it does |
| --- | --- |
| `tweak/Tweak.m` | Hooks, live reload, Bottom Area, hints, labels, iOS 26 sizing and orientation |
| `tweak/TPRPatcher.m` | Copies and patches keyboard trees |
| `tweak/TPRConfig.m` | Reads and validates settings; the single config snapshot |
| `tweak/TPRKeyRows.h` | Apple's US rows, shared by the tweak and the Keys page |
| `tweak/TPRTree.m` | Guarded helpers for UIKit's private tree objects |
| `tweak/prefs/` | The settings pane (PreferenceLoader bundle), including saved setups and their text format |
| `tools/sim/` | Simulator test bench (see below) |

## Simulator test bench

`tools/sim/tpr-sim.sh` builds a small host app plus a simulator build of the tweak, then drives the keyboard from the command line: switch planes, hit-test rows, change keyboard types and input modes, rotate and take screenshots. Put your simulator's UDID in `tools/sim/.udid` (or set `TPR_UDID`), then:

```sh
tools/sim/tpr-sim.sh build
tools/sim/tpr-sim.sh launch tweak
tools/sim/tpr-sim.sh cmd 'info' 'hitrow 30'
```

## License

MIT. See [LICENSE](LICENSE).
