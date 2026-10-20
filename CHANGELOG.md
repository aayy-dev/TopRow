# Changelog

## 2.1.0

- iOS 26 support. iOS 26 builds the iPhone keyboard a new way, which TopRow 2.0 left untouched. Now the row, the Keys page, Symbol Hints, Key Height, Bottom Area, the 123/ABC/#+= labels, the Keyboard Types switches, Show in Landscape and landscape rows all work there. Tested on an iPhone 11 with iOS 26.0.
- On iOS 26 the row also comes to other letter layouts, such as German (QWERTZ), French (AZERTY), Spanish, Russian, Greek and Arabic, spread across the full width of their first row.
- What's different on iOS 26: all pages of a keyboard share one height, so a page whose row you leave empty gets an empty band at the top instead of a shorter keyboard (its keys keep Apple's size). The email and web-address keyboards share the main keyboard's 123 and #+= pages, so those take your Keys page rows too. The name-and-phone-number keyboard stays stock.
- iOS 16.1–18 build a few minority layouts (Hausa, Yoruba, Sami and others) the new way; on those versions they stay stock, as in 2.0.
- TopRow no longer starts up in command-line tools, helper tools inside apps (such as TrollStore's) or system daemons, and its log lines no longer show up in terminal output. (The tweak loader still maps it into anything that uses UIKit; it now returns at once there.)

## 2.0.0

- New **Keys** page: change any key on the letters, Shift / Caps Lock, 123 and #+= pages. Add, remove, reorder or retype keys, up to 12 per row. Shift rows follow your letters in capitals unless you set them. Keys kept from Apple's row keep their long-press accents and your region's currency signs. Applies to the US English (QWERTY) layout in every size and keyboard type, and in landscape even with Show in Landscape off; other languages and the email and web-address number pages keep their own keys. The page has its own Preview field.
- New **Setups** page: save your settings under a name (up to 50) and switch between them. Share a setup as a text file or as text to paste; friends import it from the clipboard or Files, see what's in it, and apply it when they choose. Excluded Apps stay out of shared setups unless you include them.
- Automatic backups: TopRow saves your settings before Reset to Defaults, Reset Keys or applying a setup, and keeps the 3 newest, so each of those can be undone.
- Settings pages refresh when TopRow's settings change in another app (Settings or TweakSettings).
- Rename the #+= key too. The 123 and ABC labels moved to the Keys page.
- Settings: Keys sits right under Enabled, with a NEW badge until you open it, and the Extra Row section is now called Top Row.
- Fix: in landscape on some iPhones (the 15 Pro among them), an extra row with fewer than 10 keys was stretched past the right edge, hiding its last keys.
- Fix: NewTerm froze on launch at some keyboard heights, including the default Key Height on some iPhones.

## 1.0.1

- Fix apps (Settings, Sileo and others) hanging on launch on some setups: TopRow no longer calls UIKit while the app is still loading.
- CarPlay keyboards stay stock. The car screen keeps its keyboard height, so the extra row covered the letters.
- Share Diagnostics now also includes TopRow's log from every app (SpringBoard, Spotlight and the rest, not just Settings) and the last 3 days of iOS crash and hang reports. Reports where TopRow is on the crashed or stuck thread get that thread's stack, and the full report when it isn't huge.

## 1.0.0

- First release: a number row on the stock keyboard (1–0 on letters, symbols with Shift / Caps Lock, an extra symbol row on 123), editable rows, symbol hints, Key Height and Bottom Area sliders, landscape rows, 123/ABC labels, per-app and per-keyboard-type control, live settings and Share Diagnostics.
