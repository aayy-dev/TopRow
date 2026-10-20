#import <Foundation/Foundation.h>
#import "TPRKeyRows.h"

typedef NS_ENUM(NSInteger, TPRPlaneKind) {
    TPRPlaneLowercase,   // small letters
    TPRPlaneShifted,     // capital letters (shift / caps lock / auto-capitalization)
    TPRPlaneNumbers,     // 123 and #+=
};

// Posted (darwin notification) by the Settings pane after it writes the prefs file.
extern NSString *const TPRReloadNotification;

// Immutable snapshot of the user's settings. +current is the ONLY place the tweak
// reads configuration from; +reload swaps in a fresh snapshot from the prefs file.
@interface TPRConfig : NSObject
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL showInLandscape;
// Landscape keyboards differ from portrait ones (Show in Landscape off, or a landscape row set).
@property (nonatomic, readonly) BOOL landscapeDiffers;
// Per keyboard type (Keyboard Types sub-page); all default to YES.
@property (nonatomic, readonly) BOOL rowOnEmail;
@property (nonatomic, readonly) BOOL rowOnWeb;
@property (nonatomic, readonly) BOOL rowOnTwitter;
// Vertical scale for all key rows (1.0 = Apple's size), from the Key Height slider.
@property (nonatomic, readonly) double keyHeightScale;
// Scale for the strip under the keys (emoji / dictation buttons), from the Bottom Area slider.
@property (nonatomic, readonly) double bottomAreaScale;
// Show the lowercase row while the keyboard is only auto-capitalized (not shift/caps lock).
@property (nonatomic, readonly) BOOL lowercaseRowWhenAutoShifted;
// Show each lowercase-row key's Shift-row character as a small secondary label.
@property (nonatomic, readonly) BOOL symbolHints;
@property (nonatomic, copy, readonly) NSSet<NSString *> *excludedApps;
// Custom labels for the keyplane-switch key ("123" on letters, "ABC" on 123/#+=); nil = Apple's.
@property (nonatomic, copy, readonly) NSString *label123;
@property (nonatomic, copy, readonly) NSString *labelABC;
// Custom label for the "#+=" key on 123; nil = Apple's. (label123 also renames "123" on #+=.)
@property (nonatomic, copy, readonly) NSString *labelSymbols;
// Changes whenever anything that affects the patched keyboard changes.
@property (nonatomic, copy, readonly) NSString *fingerprint;

// Keys for the extra row on that kind of plane; empty means no extra row there.
- (NSArray<NSString *> *)rowForPlane:(TPRPlaneKind)kind;
// Same, for landscape keyboards: the landscape row if one is set, else the portrait row.
- (NSArray<NSString *> *)rowForPlane:(TPRPlaneKind)kind landscape:(BOOL)landscape;
// Keys for row `row` (0-2) of that keyplane, or nil to keep Apple's row. Shift / Caps Lock
// rows follow the letters rows in capitals unless set themselves.
- (NSArray<NSString *> *)keysForPlane:(TPRKeyPlane)plane row:(NSUInteger)row;
@property (nonatomic, readonly) BOOL hasCustomKeys;

+ (instancetype)current;
// Re-reads the prefs file; returns YES if the fingerprint changed.
+ (BOOL)reload;
+ (NSString *)prefsPath;
@end
