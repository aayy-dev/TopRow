#import <Foundation/Foundation.h>
@class TPRConfig;

// Returns a patched copy of `keyboard` with the extra row added, or nil if the
// keyboard should be used unchanged. Never mutates `keyboard` itself: the
// serializer caches and shares those nodes. *outcome receives a log line.
// `landscape` is only read for iOS 26 dynamic keyboards (one tree serves both
// orientations; other keyboards' trees tell landscape apart themselves).
id TPRPatchKeyboard(id keyboard, NSString *name, TPRConfig *config, BOOL landscape, NSString **outcome);

// For the "lowercase row while auto-capitalized" option: relabel the extra row on a
// shifted letters keyplane UIKit is showing. Returns YES if anything changed.
BOOL TPRRelabelShiftedRow(id keyplane, BOOL autoShifted, BOOL landscape, TPRConfig *config);
// YES for landscape keyboard trees (by name or by design-frame aspect ratio).
BOOL TPRIsLandscapeKeyboard(id keyboard, NSString *name);
// YES for "dynamic" keyboard trees (no geometry; TextInputUI lays them out): every iPhone
// layout on iOS 26, a few minority layouts on earlier versions.
BOOL TPRIsDynamicKeyboard(id keyboard);
// Why dynamic keyboards stay Apple's in this process, or nil when they get the row. Tweak.m
// decides at launch (iOS 26 or later, and the height hook installed); until then they stay.
void TPRSetDynamicKeyboardsUnsupported(NSString *reason);
// How much taller TextInputUI should make a dynamic keyboard: `layout` is the input mode's
// layout ("QWERTY", "QWERTZ-German", ...), as +[TUIKeyplane sizeFromScreenTraits:...] gets it.
// The added row and Key Height of that layout's keyboard as last handed to UIKit, in that
// orientation; 1 (Apple's height) for pads, keyboard types switched off and layouts not patched.
double TPRDynamicHeightFactor(NSString *layout, NSInteger keyboardType, BOOL landscape, TPRConfig *config);
// iOS 26 asks for "Dynamic-QWERTY-Small-Email" (-URL, -Twitter, -AlphaWithURL) first and falls
// back to the shared "Dynamic-QWERTY-Small" when there is no such keyboard. For a keyboard type
// whose row is switched off this returns the shared name, so that type can get its own tree.
NSString *TPRDynamicSharedName(NSString *name, TPRConfig *config);
// YES for keyplanes of a keyboard TPRPatchKeyboard returned (custom 123/ABC labels go only there).
BOOL TPRIsPatchedKeyplane(id keyplane);
