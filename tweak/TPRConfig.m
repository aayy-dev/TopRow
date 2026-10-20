#import "TPRConfig.h"
#import "TPRPaths.h"
#import <CommonCrypto/CommonDigest.h>

NSString *const TPRReloadNotification = @"dev.rtrdd.toprow/reload";

static const NSUInteger kMaxKeys = 10;
static const NSUInteger kMaxKeyLength = 8;   // characters as shown (an emoji counts as one)

static NSString *const kDefaultLowercase = @"1 2 3 4 5 6 7 8 9 0";
static NSString *const kDefaultShifted   = @"! @ # $ % ^ & * ( )";
static NSString *const kDefaultNumbers   = @"! @ # $ % ^ & * ( )";

@implementation TPRConfig {
    NSArray<NSArray<NSString *> *> *_rows;            // indexed by TPRPlaneKind
    NSArray *_landscapeRows;                           // same, NSNull = use the portrait row
    NSArray<NSArray *> *_keyRows;                      // [TPRKeyPlane][row], NSNull = Apple's row
}

// 64 bits of SHA-256, as hex. Not -[NSString hash]: CFString hashes only the first,
// middle and last 32 characters of long strings, so toggles in between went unnoticed.
static NSString *Digest(NSString *string) {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char sha[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, sha);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < 8; i++) [hex appendFormat:@"%02x", sha[i]];
    return hex;
}

// Characters as the user sees them: "👍🏽" or "🇫🇷" is one, not two to four UTF-16 units.
static NSUInteger CharacterCount(NSString *string) {
    __block NSUInteger count = 0;
    [string enumerateSubstringsInRange:NSMakeRange(0, string.length) options:NSStringEnumerationByComposedCharacterSequences
                            usingBlock:^(NSString *s, NSRange r, NSRange e, BOOL *stop) { count++; }];
    return count;
}

// "1 2 3" -> @[@"1", @"2", @"3"]; @"" -> @[] (no row); invalid -> nil.
static NSArray<NSString *> *ParseRow(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSMutableArray *keys = [NSMutableArray array];
    for (NSString *part in [value componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (!part.length) continue;
        if (CharacterCount(part) > kMaxKeyLength) return nil;
        [keys addObject:part];
    }
    return keys.count <= kMaxKeys ? keys : nil;
}

// A whole keyboard row: 1-12 keys; empty, invalid or Apple's own row -> nil (Apple's row).
static NSArray<NSString *> *ParseKeyRow(id value, TPRKeyPlane plane, NSUInteger row) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSArray<NSString *> *keys = TPRSplitKeys(value);
    if (!keys.count || keys.count > TPRMaxRowKeys) return nil;
    for (NSString *key in keys)
        if (CharacterCount(key) > TPRMaxKeyLength) return nil;
    return [keys isEqualToArray:TPRSplitKeys(TPRStockKeyRow(plane, row))] ? nil : keys;
}

// Up to 5 characters, like the stock labels; empty or invalid -> nil (Apple's label).
static NSString *ParseLabel(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *label = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return label.length && CharacterCount(label) <= 5 ? label : nil;
}

static BOOL BoolValue(id value, BOOL fallback) {
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

- (instancetype)initWithPrefs:(NSDictionary *)prefs generation:(NSUInteger)generation {
    if ((self = [super init])) {
        _enabled = BoolValue(prefs[@"Enabled"], YES);
        _showInLandscape = BoolValue(prefs[@"ShowInLandscape"], YES);
        _rowOnEmail = BoolValue(prefs[@"RowOnEmail"], YES);
        _rowOnWeb = BoolValue(prefs[@"RowOnWeb"], YES);
        _rowOnTwitter = BoolValue(prefs[@"RowOnTwitter"], YES);
        _lowercaseRowWhenAutoShifted = BoolValue(prefs[@"LowercaseRowWhenAutoShifted"], NO);
        _symbolHints = BoolValue(prefs[@"SymbolHints"], NO);
        id height = prefs[@"KeyHeight"];   // percent
        double percent = [height isKindOfClass:[NSNumber class]] ? [height doubleValue] : 100;
        _keyHeightScale = MIN(MAX(round(percent), 80), 130) / 100.0;
        id bottom = prefs[@"BottomAreaHeight"];   // percent
        double bottomPercent = [bottom isKindOfClass:[NSNumber class]] ? [bottom doubleValue] : 100;
        _bottomAreaScale = MIN(MAX(round(bottomPercent), 60), 130) / 100.0;
        _rows = @[ ParseRow(prefs[@"LowercaseRow"]) ?: ParseRow(kDefaultLowercase),
                   ParseRow(prefs[@"ShiftedRow"]) ?: ParseRow(kDefaultShifted),
                   ParseRow(prefs[@"NumbersRow"]) ?: ParseRow(kDefaultNumbers) ];
        // Landscape rows are optional: blank or invalid means "same as portrait".
        NSMutableArray *landscape = [NSMutableArray array];
        for (NSString *key in @[ @"LandscapeLowercaseRow", @"LandscapeShiftedRow", @"LandscapeNumbersRow" ]) {
            NSArray *row = ParseRow(prefs[key]);
            [landscape addObject:row.count ? row : [NSNull null]];
        }
        _landscapeRows = landscape;
        _landscapeDiffers = !_showInLandscape;
        for (NSUInteger kind = 0; kind < landscape.count; kind++)
            if ([landscape[kind] isKindOfClass:[NSArray class]] && ![landscape[kind] isEqualToArray:_rows[kind]])
                _landscapeDiffers = YES;
        _label123 = ParseLabel(prefs[@"Label123"]);
        _labelABC = ParseLabel(prefs[@"LabelABC"]);
        _labelSymbols = ParseLabel(prefs[@"LabelSymbols"]);
        NSMutableArray *keyRows = [NSMutableArray array];
        for (TPRKeyPlane plane = 0; plane < TPRKeyPlaneCount; plane++) {
            NSMutableArray *rows = [NSMutableArray array];
            for (NSUInteger row = 0; row < TPRKeyRowCount; row++) {
                NSArray *keys = ParseKeyRow(prefs[TPRKeyRowPrefsKey(plane, row)], plane, row);
                // Shift / Caps Lock follows an edited letters row unless it has its own.
                if (!keys && plane == TPRKeyPlaneShifted && ![prefs[TPRKeyRowPrefsKey(plane, row)] length] &&
                    [keyRows[TPRKeyPlaneLetters][row] isKindOfClass:[NSArray class]]) {
                    NSMutableArray *upper = [NSMutableArray array];
                    for (NSString *key in keyRows[TPRKeyPlaneLetters][row]) [upper addObject:key.uppercaseString];
                    keys = ParseKeyRow([upper componentsJoinedByString:@" "], plane, row);
                }
                [rows addObject:keys ?: [NSNull null]];
            }
            [keyRows addObject:rows];
        }
        _keyRows = keyRows;
        NSMutableSet *excluded = [NSMutableSet set];
        id apps = prefs[@"ExcludedApps"];
        if ([apps isKindOfClass:[NSArray class]])
            for (id app in apps)
                if ([app isKindOfClass:[NSString class]]) [excluded addObject:app];
        _excludedApps = excluded;

        NSMutableArray *parts = [NSMutableArray array];
        for (NSArray *row in _rows) [parts addObject:[row componentsJoinedByString:@"\x1e"]];
        for (id row in _landscapeRows)
            [parts addObject:[row isKindOfClass:[NSArray class]] ? [row componentsJoinedByString:@"\x1e"] : @"\x1d"];
        [parts addObject:_enabled ? @"E" : @"D"];
        [parts addObject:_showInLandscape ? @"L" : @"P"];
        [parts addObject:[NSString stringWithFormat:@"T%d%d%d", _rowOnEmail, _rowOnWeb, _rowOnTwitter]];
        [parts addObject:[NSString stringWithFormat:@"H%.2f B%.2f", _keyHeightScale, _bottomAreaScale]];
        [parts addObject:_lowercaseRowWhenAutoShifted ? @"A" : @"M"];
        [parts addObject:_symbolHints ? @"S" : @"-"];
        // Bump when how keys are drawn changes, so cached key images from older builds don't match.
        [parts addObject:@"render-8"];
        [parts addObject:[NSString stringWithFormat:@"%@\x1e%@\x1e%@", _label123 ?: @"", _labelABC ?: @"",
                          _labelSymbols ?: @""]];
        for (NSArray *rows in _keyRows)
            for (id row in rows)
                [parts addObject:[row isKindOfClass:[NSArray class]] ? [row componentsJoinedByString:@"\x1e"] : @"\x1d"];
        // Only whether this app is excluded: editing the list mustn't rebuild every other app's keyboard.
        NSString *app = NSBundle.mainBundle.bundleIdentifier;
        [parts addObject:app && [excluded containsObject:app] ? @"X" : @"I"];
        // The generation counts live reloads in this process: returning to an earlier
        // config must not match UIKit's views/images cached for the earlier tree.
        _fingerprint = [NSString stringWithFormat:@"%@-%lu", Digest([parts componentsJoinedByString:@"\x1f"]),
                        (unsigned long)generation];
    }
    return self;
}

- (NSArray<NSString *> *)rowForPlane:(TPRPlaneKind)kind {
    return (NSUInteger)kind < _rows.count ? _rows[kind] : @[];
}

- (NSArray<NSString *> *)rowForPlane:(TPRPlaneKind)kind landscape:(BOOL)landscape {
    id row = landscape && (NSUInteger)kind < _landscapeRows.count ? _landscapeRows[kind] : nil;
    return [row isKindOfClass:[NSArray class]] ? row : [self rowForPlane:kind];
}

- (NSArray<NSString *> *)keysForPlane:(TPRKeyPlane)plane row:(NSUInteger)row {
    if ((NSUInteger)plane >= _keyRows.count || row >= TPRKeyRowCount) return nil;
    id keys = _keyRows[plane][row];
    return [keys isKindOfClass:[NSArray class]] ? keys : nil;
}

- (BOOL)hasCustomKeys {
    for (TPRKeyPlane plane = 0; plane < TPRKeyPlaneCount; plane++)
        for (NSUInteger row = 0; row < TPRKeyRowCount; row++)
            if ([self keysForPlane:plane row:row]) return YES;
    return NO;
}

+ (NSString *)prefsPath {
#if TPR_SIMULATOR
    const char *override = getenv("TPR_PREFS_PATH");
    if (override) return @(override);
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"dev.rtrdd.toprow.plist"];
#else
    return TPRPrefsFile;
#endif
}

static TPRConfig *gCurrent;

static NSUInteger gGeneration;

static TPRConfig *LoadFromDisk(void) {
    // Read the file directly: the Settings pane writes it itself, and sandboxed apps
    // can read it but can't reach cfprefsd for another app's domain.
    NSData *data = [NSData dataWithContentsOfFile:[TPRConfig prefsPath]];
    id prefs = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
    return [[TPRConfig alloc] initWithPrefs:[prefs isKindOfClass:[NSDictionary class]] ? prefs : @{} generation:gGeneration];
}

+ (instancetype)current {
    @synchronized(self) {
        if (!gCurrent) gCurrent = LoadFromDisk();
        return gCurrent;
    }
}

+ (BOOL)reload {
    @synchronized(self) {
        TPRConfig *fresh = LoadFromDisk();
        if ([fresh.fingerprint isEqualToString:gCurrent.fingerprint]) return NO;
        gGeneration++;
        gCurrent = LoadFromDisk();
        return YES;
    }
}

@end
