// TopRow — adds a number/symbol row to the stock iOS keyboard.
//
// Injection point: -[TUIKBGraphSerialization keyboardForName:]
// returns the UIKBTree a keyboard is built from. We hand back a patched copy
// with one extra row. The cacheIdentifierForKeyplaneNamed: suffix only keys
// UIKeyboardLayoutStar's in-memory keyplane-view map; rendered keyplane images
// are keyed by UIKBCacheToken_Keyplane (plane name, frame, keyset/geometry set
// names; not labels), so the patcher folds the config fingerprint into the
// keyset/geometry-set names.

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import "TPRConfig.h"
#import "TPRPaths.h"
#import "TPRPatcher.h"
#import "TPRTree.h"

// Logs to the system log (os_log; NSLog would also print to stderr), keeps the last few
// lines in memory for the Settings pane's "Share Diagnostics" (plain text, by design), and
// appends to a shared log file from every process allowed to write it (SpringBoard,
// Settings, unsandboxed apps), so the report can show what happened elsewhere. Sandboxed
// apps can't write it; that's fine.
static NSMutableArray<NSString *> *gRecentLog;

static void TPRAppendToLogFile(NSString *entry) {
    static int fd = -2;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = TPRRootPath(@"/var/mobile/Library/Logs/TopRow");
        NSString *path = [dir stringByAppendingPathComponent:@"TopRow.log"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        struct stat st;
        if (stat(path.fileSystemRepresentation, &st) == 0 && st.st_size > 256 * 1024)   // keep two files, ~512 KB
            rename(path.fileSystemRepresentation, [path stringByAppendingString:@".1"].fileSystemRepresentation);
        fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0666);
    });
    if (fd < 0) return;
    NSString *line = [NSString stringWithFormat:@"%@[%d] %@\n", NSProcessInfo.processInfo.processName,
                      getpid(), entry];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    write(fd, data.bytes, data.length);   // one write per line: O_APPEND keeps lines whole across processes
}

static void TPRRecord(NSString *line) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gRecentLog = [NSMutableArray array]; });
    NSString *entry = [NSString stringWithFormat:@"%@ %@", [NSDate date], line];
    @synchronized(gRecentLog) {
        [gRecentLog addObject:entry];
        if (gRecentLog.count > 40) [gRecentLog removeObjectAtIndex:0];
    }
    TPRAppendToLogFile(entry);
}

// Looked up with dlsym by the Settings pane (same process).
__attribute__((visibility("default"))) NSArray<NSString *> *TPRRecentLog(void) {
    if (!gRecentLog) return @[];
    @synchronized(gRecentLog) { return [gRecentLog copy]; }
}

#define TPRLog(fmt, ...) do { NSString *_l = [NSString stringWithFormat:fmt, ##__VA_ARGS__]; \
    os_log(OS_LOG_DEFAULT, "[TopRow] %{public}@", _l); TPRRecord(_l); } while (0)


static id (*orig_keyboardForName)(id, SEL, NSString *);
static id (*orig_cacheIdentifierForKeyplaneNamed)(id, SEL, NSString *);

// iOS 26 builds one keyboard tree for both orientations; while UIKit loads a keyboard for
// landscape screen traits (and landscape differs from portrait), this is set and the
// keyboard is patched for landscape. Main thread only, like keyboard loading.
static BOOL gLoadingLandscape;

static id hook_keyboardForName(id self, SEL _cmd, NSString *name) {
    id keyboard = orig_keyboardForName(self, _cmd, name);
    if (!keyboard) {
        // iOS 26: "...-Email" has no keyboard of its own and UIKit falls back to the shared
        // one. With that type's row turned off, answer for the type with the shared keyboard
        // handled under the type's name (left as Apple's), so the other types keep the row.
        NSString *shared = TPRDynamicSharedName(name, [TPRConfig current]);
        keyboard = shared ? orig_keyboardForName(self, _cmd, shared) : nil;
        if (!keyboard || !TPRIsDynamicKeyboard(keyboard)) return nil;
    }
#if TPR_SIMULATOR
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tpr-raw"];
    NSString *path = [dir stringByAppendingPathComponent:[name stringByAppendingString:@".txt"]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        [TPRDescribeTree(keyboard) writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    TPRLog(@"keyboardForName:%@ returned %p", name, keyboard);
#endif
    NSString *outcome = nil;
    TPRConfig *config = [TPRConfig current];
    id patched = TPRPatchKeyboard(keyboard, name, config, gLoadingLandscape && config.landscapeDiffers, &outcome);
    // Only decisions: UIKit asks many times per keyboard, and "cached" lines would push the
    // useful ones out of the diagnostics buffer.
    if (![outcome isEqualToString:@"cached"]) TPRLog(@"keyboardForName:%@ -> %@", name, outcome);
    return patched ?: keyboard;
}

// (iOS 26's dynamic keyboards never ask for this: their key views are cached by key name.)
static id hook_cacheIdentifierForKeyplaneNamed(id self, SEL _cmd, NSString *planeName) {
    id identifier = orig_cacheIdentifierForKeyplaneNamed(self, _cmd, planeName);
    if (![identifier isKindOfClass:[NSString class]]) return identifier;
    NSString *patched = [identifier stringByAppendingFormat:@"-TopRow-%@", [TPRConfig current].fingerprint];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ TPRLog(@"cache identifier %@", patched); });
    return patched;
}

// Settings changed: take the new snapshot and make the current process rebuild its
// keyboard. -[UIKeyboardImpl clearLayouts] drops UIKit's cached layouts (which
// otherwise keep the old tree by name); if a keyboard is on screen, dismissing and
// re-showing it makes UIKit ask keyboardForName: again. Suspended apps get this
// when they resume; apps that went to the background already dropped their layouts.
static id CallObject(id target, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    return [target respondsToSelector:sel] ? ((id (*)(id, SEL))objc_msgSend)(target, sel) : nil;
}

static void CallVoid(id target, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if ([target respondsToSelector:sel]) ((void (*)(id, SEL))objc_msgSend)(target, sel);
}

static void ApplyConfigChange(void) {
    if (![TPRConfig reload]) return;
    TPRLog(@"config changed -> %@", [TPRConfig current].fingerprint);
    id impl = CallObject(NSClassFromString(@"UIKeyboardImpl"), @"activeInstance");
    CallVoid(impl, @"clearLayouts");
    UIResponder *responder = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            if (window.isKeyWindow) responder = CallObject(window, @"firstResponder");
    }
    if (responder.isFirstResponder && [responder canResignFirstResponder] && [responder resignFirstResponder])
        dispatch_async(dispatch_get_main_queue(), ^{ [responder becomeFirstResponder]; });
}

static void OnReloadNotification(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                                 const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ ApplyConfigChange(); });
}

// ---- "lowercase row while auto-capitalized" ------------------------------------

static void (*orig_setShift)(id, SEL, BOOL);
static void (*orig_setAutoshift)(id, SEL, BOOL);
static void (*orig_setKeyplaneName)(id, SEL, NSString *);
static BOOL gRelabeling;

static BOOL CallBool(id target, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    return [target respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(target, sel);
}

static void RefreshKeyViewHints(UIView *view, int depth);

// iOS 26: the layout's TUIKeyplaneView (TextInputUI), if it uses one.
static UIView *DynamicKeyplaneView(UIView *view, int depth) {
    if ([view isKindOfClass:NSClassFromString(@"TUIKeyplaneView")]) return view;
    if (depth > 6) return nil;
    for (UIView *child in view.subviews) {
        UIView *found = DynamicKeyplaneView(child, depth + 1);
        if (found) return found;
    }
    return nil;
}

static void UpdateShiftedRow(id layout) {
    TPRConfig *config = [TPRConfig current];
    if (gRelabeling || !config.lowercaseRowWhenAutoShifted) return;
    id keyboard = CallObject(layout, @"keyboard");
    // iOS 26: reloading the same keyplane keeps TextInputUI's key views, which it finds by key
    // name, so the renamed keys would get new views that aren't on screen (pressing one then
    // crashes). The keyplane view has to lay its keys out again, so without a way to do that
    // the row isn't relabeled at all.
    UIView *keyplaneView = nil;
    SEL reset = NSSelectorFromString(@"resetLayoutAndApplyKeyplane:");
    if (TPRIsDynamicKeyboard(keyboard)) {
        keyplaneView = [layout isKindOfClass:[UIView class]] ? DynamicKeyplaneView(layout, 0) : nil;
        if (![keyplaneView respondsToSelector:reset] ||
            ![keyplaneView respondsToSelector:NSSelectorFromString(@"currentKeyplane")]) {
            static dispatch_once_t once;
            if (keyplaneView) dispatch_once(&once, ^{ TPRLog(@"can't relabel the row on this iOS (keyplane view)"); });
            return;
        }
    }
    id impl = CallObject(NSClassFromString(@"UIKeyboardImpl"), @"activeInstance");
    BOOL autoShifted = CallBool(layout, @"autoShift") && !CallBool(impl, @"isShiftLocked");
    BOOL landscape = TPRIsLandscapeKeyboard(keyboard, CallObject(layout, @"keyboardName"));
    if (!TPRRelabelShiftedRow(CallObject(layout, @"keyplane"), autoShifted, landscape, config)) return;
    gRelabeling = YES;
    CallVoid(layout, @"reloadCurrentKeyplane");
    gRelabeling = NO;
    id model = CallObject(keyplaneView, @"currentKeyplane");
    if (model) {
        ((void (*)(id, SEL, id))objc_msgSend)(keyplaneView, reset, model);
        RefreshKeyViewHints(keyplaneView, 0);
    }
}

static void hook_setShift(id self, SEL _cmd, BOOL shift) {
    orig_setShift(self, _cmd, shift);
    UpdateShiftedRow(self);
}

static void hook_setAutoshift(id self, SEL _cmd, BOOL autoshift) {
    orig_setAutoshift(self, _cmd, autoshift);
    UpdateShiftedRow(self);
}

static void hook_setKeyplaneName(id self, SEL _cmd, NSString *name) {
    orig_setKeyplaneName(self, _cmd, name);
    UpdateShiftedRow(self);
}

// ---- Bottom Area slider: the strip under the keys ------------------------------
//
// UIKit pins the keys' container above the bottom edge with a constraint named
// "inputView.bottom" (-58pt on an iPhone 15 Pro); the emoji/dictation buttons sit in
// that gap inside UIKeyboardDockView. Scale the gap, and scale its contents with it,
// keeping their distance from the bottom proportional so they stay inside the strip.

static void (*orig_dockLayoutSubviews)(id, SEL);
static char kOriginalConstantKey;

// What's actually drawn inside a dock item, in its own bounds: a button's image, a
// collection view's cells (the item's frame is often much taller than its icon).
static CGRect VisibleRect(UIView *item) {
    if ([item isKindOfClass:[UIButton class]] && ((UIButton *)item).imageView.image)
        return ((UIButton *)item).imageView.frame;
    if ([item isKindOfClass:[UICollectionView class]]) {
        CGRect cells = CGRectNull;
        for (UICollectionViewCell *cell in ((UICollectionView *)item).visibleCells) cells = CGRectUnion(cells, cell.frame);
        if (!CGRectIsNull(cells)) return cells;   // bounds coordinates, like item.bounds below
    }
    CGFloat h = MIN(item.bounds.size.height, 34);
    return CGRectMake(0, CGRectGetMidY(item.bounds) - h / 2, item.bounds.size.width, h);
}

static void ScaleBottomArea(UIView *dock, double scale) {
    for (NSLayoutConstraint *c in dock.superview.constraints) {
        if (![c.identifier isEqualToString:@"inputView.bottom"]) continue;
        // @[Apple's value, the value we last set]. If the constant no longer matches what we
        // set, UIKit has changed it (another keyboard type or orientation): that's the new
        // original. At 100% an untouched constraint is left alone.
        NSArray<NSNumber *> *state = objc_getAssociatedObject(c, &kOriginalConstantKey);
        if (!state || fabs(c.constant - state[1].doubleValue) > 0.5) state = @[ @(c.constant), @(c.constant) ];
        CGFloat wanted = state[0].doubleValue * scale;
        if (fabs(c.constant - wanted) > 0.5) c.constant = wanted;
        objc_setAssociatedObject(c, &kOriginalConstantKey, @[ state[0], @(c.constant) ], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Every direct subview: Apple's emoji/dictation buttons, and bars other tweaks put
    // in the dock (e.g. KBApp's KBDockCollectionView). Two stages: first use up the
    // empty padding (move the item, full size); only when it no longer fits between
    // the home-indicator clearance and the keys, shrink it just enough.
    const CGFloat homeClearance = 12, gapUnderKeys = 4;
    // The gap's size: iOS 26 writes the constraint the other way round (+58, not -58).
    CGFloat strip = 0;
    for (NSLayoutConstraint *c in dock.superview.constraints)
        if ([c.identifier isEqualToString:@"inputView.bottom"]) strip = fabs(c.constant);
    for (UIView *item in dock.subviews) {
        CGAffineTransform t = CGAffineTransformIdentity;
        if (scale != 1 && strip > 0) {
            // Transforms scale about the item's center (center/bounds ignore transforms).
            CGRect visible = VisibleRect(item);
            CGFloat content = visible.size.height;
            CGFloat offset = CGRectGetMidY(visible) - CGRectGetMidY(item.bounds);   // + = below center
            CGFloat itemFromBottom = dock.bounds.size.height - item.center.y;
            CGFloat contentFromBottom = itemFromBottom - offset;
            CGFloat band = strip - homeClearance - gapUnderKeys;
            CGFloat fit = MAX(MIN(1, band / content), 0.5);
            CGFloat target = MIN(contentFromBottom, strip - gapUnderKeys - content * fit / 2);
            target = MAX(target, homeClearance + content * fit / 2);
            CGFloat down = itemFromBottom - offset * fit - target;
            t = CGAffineTransformScale(CGAffineTransformMakeTranslation(0, down), fit, fit);
        }
        if (!CGAffineTransformEqualToTransform(item.transform, t)) item.transform = t;
    }
}

static void hook_dockLayoutSubviews(UIView *self, SEL _cmd) {
    orig_dockLayoutSubviews(self, _cmd);
    TPRConfig *config = [TPRConfig current];
    NSString *app = NSBundle.mainBundle.bundleIdentifier;
    BOOL active = config.enabled && !(app && [config.excludedApps containsObject:app]);
    ScaleBottomArea(self, active ? config.bottomAreaScale : 1);
}

// ---- custom 123 / ABC / #+= labels -------------------------------------------------
// UIKit localizes the keyplane-switch keys in updateLocalizedKeysOnKeyplane:; override
// their labels afterwards. "More-Key" reads "123" on letters and "ABC" elsewhere; on 123
// and #+= the Shift key switches between them and reads "#+=" or "123".

static void (*orig_updateLocalizedKeys)(id, SEL, id);

static void hook_updateLocalizedKeys(id self, SEL _cmd, id keyplane) {
    orig_updateLocalizedKeys(self, _cmd, keyplane);
    TPRConfig *config = [TPRConfig current];
    if (!config.enabled || (!config.label123 && !config.labelABC && !config.labelSymbols)) return;
    NSString *app = NSBundle.mainBundle.bundleIdentifier;
    if (app && [config.excludedApps containsObject:app]) return;
    if (!TPRIsPatchedKeyplane(keyplane)) return;   // Apple's own trees keep Apple's labels
    BOOL letters = CallBool(keyplane, @"isAlphabeticPlane");
    BOOL shifted = CallBool(keyplane, @"isShiftKeyplane");
    for (id key in CallObject(keyplane, @"keys")) {
        NSString *name = TPRName(key), *label = nil;
        if ([name isEqualToString:@"More-Key"]) label = letters ? config.label123 : config.labelABC;
        else if ([name isEqualToString:@"Shift-Key"] && !letters) label = shifted ? config.label123 : config.labelSymbols;
        if (!label) continue;
        NSMutableDictionary *props = [TPRProperties(key) mutableCopy];
        props[@"KBdisplayString"] = label;
        [(id<TPRKBTree>)key setProperties:props];
    }
}

// ---- symbol hints: small label in the top-right corner of row keys ---------------------
// UIKit draws a keyplane into one image, so overlay labels on the keyplane view, using
// each key's laid-out frame and the keyboard's text color.

static void (*orig_keyplaneLayoutSubviews)(id, SEL);
static const NSInteger kHintTag = 0x5C10;

static UILabel *NewHintLabel(void) {
    UILabel *label = [UILabel new];
    label.tag = kHintTag;
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    label.adjustsFontSizeToFitWidth = YES;   // multi-character keys like ".com"
    label.minimumScaleFactor = 0.5;
    label.textColor = [UIColor.labelColor colorWithAlphaComponent:0.55];
    label.textAlignment = NSTextAlignmentRight;
    label.userInteractionEnabled = NO;
    return label;
}

static void hook_keyplaneLayoutSubviews(UIView *self, SEL _cmd) {
    orig_keyplaneLayoutSubviews(self, _cmd);
    // This runs on every layout pass: reuse the labels from the last one.
    NSMutableArray<UILabel *> *spare = [NSMutableArray array];
    for (UIView *v in self.subviews)
        if (v.tag == kHintTag && [v isKindOfClass:[UILabel class]]) [spare addObject:(UILabel *)v];
    NSMutableArray<UILabel *> *used = [NSMutableArray array];
    if ([TPRConfig current].symbolHints) {
        for (id key in CallObject(CallObject(self, @"keyplane"), @"keys")) {
            NSString *hint = TPRProperties(key)[@"TPRhint"];
            CGRect frame;
            if (![hint isKindOfClass:[NSString class]] || !TPRGetFrames(key, NULL, &frame) || CGRectIsEmpty(frame)) continue;
            UILabel *label = spare.firstObject;
            if (label) {
                [spare removeObjectAtIndex:0];
            } else {
                label = NewHintLabel();
                [self addSubview:label];
            }
            if (![label.text isEqualToString:hint]) label.text = hint;
            CGRect target = CGRectMake(CGRectGetMaxX(frame) - 20, CGRectGetMinY(frame) + 2, 16, 13);
            if (!CGRectEqualToRect(label.frame, target)) label.frame = target;
            [used addObject:label];
        }
    }
    for (UILabel *label in spare) [label removeFromSuperview];
    // Keep them above the key artwork if UIKit added views since the last pass.
    if (used.count && self.subviews.lastObject.tag != kHintTag)
        for (UILabel *label in used) [self bringSubviewToFront:label];
}

// iOS 26 (TextInputUI) gives every key a view of its own (TUIKBKeyView, laid out with Auto
// Layout) and never uses UIKBKeyplaneView, so the hint goes on the key's view. (Keys can
// show a second string natively, but only as iPad-style flick keys: drawn over the main
// label, and swiping down types it.) The keycap is drawn inset in the view, about 1pt from
// its top and 4pt from its right edge; the hint sits in that corner like the old one.
static void (*orig_keyViewLayoutSubviews)(id, SEL);

static void UpdateKeyViewHint(UIView *keyView) {
    id key = CallObject(keyView, @"key");
    NSString *hint = [TPRConfig current].symbolHints ? TPRProperties(key)[@"TPRhint"] : nil;
    UILabel *label = nil;
    for (UIView *v in keyView.subviews)
        if (v.tag == kHintTag && [v isKindOfClass:[UILabel class]]) label = (UILabel *)v;
    if (![hint isKindOfClass:[NSString class]]) {
        [label removeFromSuperview];   // a key without a hint now (relabeled, or hints turned off)
        return;
    }
    if (!label) [keyView addSubview:(label = NewHintLabel())];
    if (![label.text isEqualToString:hint]) label.text = hint;
    CGRect target = CGRectMake(CGRectGetMaxX(keyView.bounds) - 24.5, 3, 16, 13);
    if (!CGRectEqualToRect(label.frame, target)) label.frame = target;
    if (keyView.subviews.lastObject != label) [keyView bringSubviewToFront:label];
}

static void hook_keyViewLayoutSubviews(UIView *self, SEL _cmd) {
    orig_keyViewLayoutSubviews(self, _cmd);
    UpdateKeyViewHint(self);
}

// After keys changed in place (the auto-capitalized row), which needn't lay their views out again.
static void RefreshKeyViewHints(UIView *view, int depth) {
    if ([view isKindOfClass:NSClassFromString(@"TUIKBKeyView")]) {
        UpdateKeyViewHint(view);
        return;
    }
    if (depth < 8)
        for (UIView *child in view.subviews) RefreshKeyViewHints(child, depth + 1);
}

// ---- NewTerm: a SwiftUI view that never settles ---------------------------------------
// NewTerm centers its bell HUD (54pt, a SwiftUI view that resizes to fit) above the
// keyboard. At some keyboard heights (TopRow's default on an iPhone 14 Pro Max, iOS 16.2)
// SwiftUI measures it 54 and 54.33pt on alternate layout passes, so the app hangs at
// launch. In NewTerm, a sub-pixel size change on a SwiftUI hosting view is that rounding
// noise: drop it.

static void (*orig_setConstant)(NSLayoutConstraint *, SEL, CGFloat);

static void hook_setConstant(NSLayoutConstraint *self, SEL _cmd, CGFloat constant) {
    CGFloat change = fabs(constant - self.constant);
    if (change > 0 && change < 0.5 &&
        (self.firstAttribute == NSLayoutAttributeWidth || self.firstAttribute == NSLayoutAttributeHeight) &&
        [NSStringFromClass(object_getClass(self.firstItem)) hasPrefix:@"_TtGC7SwiftUI14_UIHostingView"])
        return;
    orig_setConstant(self, _cmd, constant);
}

// ---- iOS 26 dynamic keyboards: height and orientation ------------------------------------
// TextInputUI sizes a dynamic keyboard from the screen and the layout's base height
// (+[TUIKeyplane sizeFromScreenTraits:layout:layoutClass:]) and splits that height between
// its rows, so an added row would squeeze the others. Grow the height by the rows the
// patcher added to that layout's keyboard (in that orientation), and apply Key Height.

static CGSize (*orig_sizeFromScreenTraits)(id, SEL, id, id, long long);
static CGSize (*orig_sizeFromScreenTraitsKeyplane)(id, SEL, id, id, id, long long);
static CGSize (*orig_keyplaneSizeForLayout)(id, SEL, id, id, long long);
static id (*orig_keyboardWithNameScreenTraits)(id, SEL, NSString *, id);
static id (*orig_keyForKeyboardName)(id, SEL, NSString *, id);
static long long gSizingKeyboardType = -1;   // main thread: the type +keyplaneSizeForLayout: asks about

static BOOL ActiveInThisApp(TPRConfig *config) {
    NSString *app = NSBundle.mainBundle.bundleIdentifier;
    return config.enabled && !(app && [config.excludedApps containsObject:app]);
}

// Screen traits for a landscape keyboard: the orientation, or a keyboard wider than the
// screen's short side (UIKit also sizes with portrait-oriented traits during a rotation).
static BOOL TraitsAreLandscape(id traits) {
    long long orientation = [traits respondsToSelector:@selector(orientation)]
        ? ((long long (*)(id, SEL))objc_msgSend)(traits, @selector(orientation)) : 0;
    if (UIInterfaceOrientationIsLandscape((UIInterfaceOrientation)orientation)) return YES;
    SEL widthSel = NSSelectorFromString(@"keyboardWidth");
    double width = [traits respondsToSelector:widthSel] ? ((double (*)(id, SEL))objc_msgSend)(traits, widthSel) : 0;
    CGRect screen = UIScreen.mainScreen.fixedCoordinateSpace.bounds;
    return width > MIN(screen.size.width, screen.size.height) + 1;
}

static CGSize hook_keyplaneSizeForLayout(id self, SEL _cmd, id layout, id traits, long long keyboardType) {
    long long saved = gSizingKeyboardType;
    gSizingKeyboardType = keyboardType;
    CGSize size = orig_keyplaneSizeForLayout(self, _cmd, layout, traits, keyboardType);
    gSizingKeyboardType = saved;
    return size;
}

static CGSize DynamicKeyboardSize(CGSize size, id layout, long long layoutClass) {
    // iPhone keyboards are layout class 1 ("Small"). A keyplane view that doesn't have its
    // keyplane yet asks for class 0 first; other classes are iPad sizes.
    TPRConfig *config = [TPRConfig current];
    if (layoutClass != 1 || size.height <= 0 || !ActiveInThisApp(config)) return size;
    long long type = gSizingKeyboardType;
    if (type < 0) {   // the keyboard on screen
        id inputTraits = CallObject(CallObject(NSClassFromString(@"UIKeyboardImpl"), @"activeInstance"), @"textInputTraits");
        type = [inputTraits respondsToSelector:@selector(keyboardType)] ? (long long)[inputTraits keyboardType] : 0;
    }
    // UIKit's own orientation decision, from the shape it chose (portrait ~1.5-1.9, landscape > 3).
    BOOL landscape = size.width / size.height > 2.4;
    double factor = TPRDynamicHeightFactor(layout, (NSInteger)type, landscape, config);
    if (factor > 0.5 && factor < 3 && fabs(factor - 1) > 0.001) size.height = round(size.height * factor);
    return size;
}

static CGSize hook_sizeFromScreenTraits(id self, SEL _cmd, id traits, id layout, long long layoutClass) {
    return DynamicKeyboardSize(orig_sizeFromScreenTraits(self, _cmd, traits, layout, layoutClass), layout, layoutClass);
}

// iOS 27 also passes the keyplane's name (and calls the layout "keyboardName").
static CGSize hook_sizeFromScreenTraitsKeyplane(id self, SEL _cmd, id traits, id layout, id keyplane, long long layoutClass) {
    return DynamicKeyboardSize(orig_sizeFromScreenTraitsKeyplane(self, _cmd, traits, layout, keyplane, layoutClass),
                               layout, layoutClass);
}

// UIKit loads a keyboard for the screen traits it has at the time (and keeps it, under
// -keyForKeyboardName:screenTraits:, for both orientations). Tell the patcher which one.
static id hook_keyboardWithNameScreenTraits(id self, SEL _cmd, NSString *name, id traits) {
    BOOL saved = gLoadingLandscape;
    gLoadingLandscape = TraitsAreLandscape(traits);
    id keyboard = orig_keyboardWithNameScreenTraits(self, _cmd, name, traits);
    gLoadingLandscape = saved;
    return keyboard;
}

// The key UIKeyboardLayoutStar caches a loaded keyboard under is the same in both
// orientations for dynamic keyboards, so a rotation reuses the tree. When landscape is
// meant to differ, give landscape its own key: rotating then loads the landscape copy.
static BOOL IsLandscapeDynamicCopy(id layoutStar, NSString *keyboardName, id traits) {
    TPRConfig *config = [TPRConfig current];
    return orig_keyForKeyboardName && [keyboardName isKindOfClass:[NSString class]] && [keyboardName hasPrefix:@"Dynamic-"] &&
           config.landscapeDiffers && ActiveInThisApp(config) && TraitsAreLandscape(traits);
}

static id hook_keyForKeyboardName(id self, SEL _cmd, NSString *name, id traits) {
    id key = orig_keyForKeyboardName(self, _cmd, name, traits);
    if ([key isKindOfClass:[NSString class]] && IsLandscapeDynamicCopy(self, name, traits))
        key = [key stringByAppendingString:@"-TopRowLandscape"];
    return key;
}

// On rotation UIKit calls -setKeyboardName:appearance: again, but keeps its keyboard when
// the name (and appearance, type) didn't change, as a dynamic keyboard's doesn't. If the
// layout's keyboard was loaded for the other orientation's copy, forget the name first so
// UIKit takes the new-keyboard path (the copy comes from its cache, by the key above).
static void (*orig_setKeyboardNameAppearance)(id, SEL, NSString *, long long);
static char kLoadedLandscapeKey;

static void hook_setKeyboardNameAppearance(id self, SEL _cmd, NSString *name, long long appearance) {
    BOOL landscape = IsLandscapeDynamicCopy(self, name, CallObject(self, @"screenTraits"));
    NSNumber *loaded = objc_getAssociatedObject(self, &kLoadedLandscapeKey);
    static Ivar nameIvar;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ nameIvar = class_getInstanceVariable(NSClassFromString(@"UIKeyboardLayoutStar"), "_keyboardName"); });
    if (loaded && loaded.boolValue != landscape && nameIvar && [name isEqual:object_getIvar(self, nameIvar)])
        object_setIvarWithStrongDefault(self, nameIvar, nil);
    orig_setKeyboardNameAppearance(self, _cmd, name, appearance);
    objc_setAssociatedObject(self, &kLoadedLandscapeKey, @(landscape), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// A class method of `className` returning a CGSize, taking `arguments` arguments (with self and _cmd).
static Method SizeMethod(NSString *className, NSString *selName, unsigned arguments) {
    Class cls = NSClassFromString(className);
    Method method = cls ? class_getClassMethod(cls, NSSelectorFromString(selName)) : NULL;
    if (!method || method_getNumberOfArguments(method) != arguments) return NULL;
    char *returns = method_copyReturnType(method);
    BOOL size = returns && !strncmp(returns, "{CGSize=", 8);
    free(returns);
    return size ? method : NULL;
}

// Dynamic keyboards get the row only if this works: an added row without it squeezes them all.
static BOOL HookDynamicSizing(void) {
    Method typeMethod = SizeMethod(@"TUIKeyplaneView", @"keyplaneSizeForLayout:screenTraits:keyboardType:", 5);
    Method sizeMethod = SizeMethod(@"TUIKeyplane", @"sizeFromScreenTraits:layout:layoutClass:", 5);
    Method keyplaneSizeMethod = sizeMethod ? NULL                                     // iOS 27:
        : SizeMethod(@"TUIKeyplane", @"sizeFromScreenTraits:keyboardName:keyplaneName:layoutClass:", 6);
    if (!typeMethod || (!sizeMethod && !keyplaneSizeMethod)) return NO;
    orig_keyplaneSizeForLayout = (CGSize (*)(id, SEL, id, id, long long))method_setImplementation(
        typeMethod, (IMP)hook_keyplaneSizeForLayout);
    if (sizeMethod)
        orig_sizeFromScreenTraits = (CGSize (*)(id, SEL, id, id, long long))method_setImplementation(
            sizeMethod, (IMP)hook_sizeFromScreenTraits);
    else
        orig_sizeFromScreenTraitsKeyplane = (CGSize (*)(id, SEL, id, id, id, long long))method_setImplementation(
            keyplaneSizeMethod, (IMP)hook_sizeFromScreenTraitsKeyplane);
    return YES;
}

// Orientation of dynamic keyboards (Show in Landscape off, landscape rows): all or nothing.
static void HookDynamicOrientation(void) {
    Class starClass = NSClassFromString(@"UIKeyboardLayoutStar");
    Method loadMethod = class_getClassMethod(starClass, NSSelectorFromString(@"keyboardWithName:screenTraits:"));
    Method keyMethod = class_getInstanceMethod(starClass, NSSelectorFromString(@"keyForKeyboardName:screenTraits:"));
    Method nameMethod = class_getInstanceMethod(starClass, NSSelectorFromString(@"setKeyboardName:appearance:"));
    if (!loadMethod || !keyMethod || !nameMethod || !class_getInstanceVariable(starClass, "_keyboardName")) {
        TPRLog(@"landscape hooks missing on this iOS");
        return;
    }
    orig_keyboardWithNameScreenTraits = (id (*)(id, SEL, NSString *, id))method_setImplementation(
        loadMethod, (IMP)hook_keyboardWithNameScreenTraits);
    orig_keyForKeyboardName = (id (*)(id, SEL, NSString *, id))method_setImplementation(
        keyMethod, (IMP)hook_keyForKeyboardName);
    orig_setKeyboardNameAppearance = (void (*)(id, SEL, NSString *, long long))method_setImplementation(
        nameMethod, (IMP)hook_setKeyboardNameAppearance);
}

static Method TargetMethod(NSString *className, SEL sel) {
    Class cls = NSClassFromString(className);
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!method) TPRLog(@"hook target missing: -[%@ %@]", className, NSStringFromSelector(sel));
    return method;
}

static void HookMethod(NSString *className, SEL sel, IMP replacement, IMP *original) {
    Class cls = NSClassFromString(className);
    Method method = class_getInstanceMethod(cls, sel);
    *original = method_getImplementation(method);
    // If the method is inherited, add an override on this class rather than
    // replacing the superclass implementation for every subclass.
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method)))
        *original = method_setImplementation(method, replacement);
}

// From the model identifier, not UIDevice: this runs in the dylib constructor, and touching
// UIKit there can deadlock app launch against UIKit's own startup thread (0x8badf00d hangs).
static BOOL IsPad(void) {
#if TPR_SIMULATOR
    const char *model = getenv("SIMULATOR_MODEL_IDENTIFIER");
    return model && strncmp(model, "iPad", 4) == 0;
#else
    char model[64] = "";
    size_t size = sizeof(model);
    return sysctlbyname("hw.machine", model, &size, NULL, 0) == 0 && strncmp(model, "iPad", 4) == 0;
#endif
}

// This build's LC_UUID. Hang reports name images only by UUID, so it goes into the log
// for Share Diagnostics to recognize this build in them after an update.
static NSString *OwnUUID(void) {
    Dl_info info;
    if (!dladdr((const void *)&OwnUUID, &info) || !info.dli_fbase) return @"?";
    const struct mach_header_64 *mh = info.dli_fbase;
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t c = 0; c < mh->ncmds; c++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize))
        if (lc->cmd == LC_UUID) return [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)lc)->uuid].UUIDString;
    return @"?";
}

// The filter (Bundles = com.apple.UIKit) loads us into anything with UIKit loaded, including
// command-line tools and daemons, and ElleKit filters can't exclude processes, so this decides.
static BOOL ShouldLoadInProcess(void) {
    char exe[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) != 0) return NO;
    const char *slash = strrchr(exe, '/');
    if (!slash) return NO;
    size_t dirLength = (size_t)(slash - exe);
    BOOL app = dirLength > 4 && !strncmp(slash - 4, ".app", 4);
    BOOL appex = dirLength > 6 && !strncmp(slash - 6, ".appex", 6);
    // Only an executable directly inside a .app or .appex (iOS bundles are flat): not
    // command-line tools, daemons, or XPC services nested in an app.
    if (!app && !appex) return NO;
    // Apple daemons wrapped in .app bundles inside frameworks (imagent, sociallayerd, IDS
    // agents, ...). Only .app: share sheets and other extensions live in frameworks' PlugIns.
    if (app && memmem(exe, dirLength, ".framework/", 11)) return NO;
    // A helper tool next to an app's own executable (trollstorehelper): its main bundle is the
    // app, so it has to be the executable the app declares.
    NSString *declared = NSBundle.mainBundle.infoDictionary[@"CFBundleExecutable"];
    if (![declared isKindOfClass:[NSString class]] || strcasecmp(declared.fileSystemRepresentation, slash + 1) != 0)
        return NO;
    if (app) return YES;   // real apps, incl. SpringBoard, InputUI, Spotlight
    // Extensions: only share sheets, action extensions and password managers' AutoFill
    // sheets (their text fields use the stock keyboard in-process). Never custom
    // keyboards, widgets, etc.
    NSString *point = NSBundle.mainBundle.infoDictionary[@"NSExtension"][@"NSExtensionPointIdentifier"];
    return [@[ @"com.apple.share-services", @"com.apple.ui-services",
               @"com.apple.authentication-services-credential-provider-ui" ] containsObject:point ?: @""];
}

__attribute__((constructor)) static void TPRInit(void) {
    @autoreleasepool {
        if (!ShouldLoadInProcess()) return;
        // iPhone only: iPad keyboards are laid out differently (and already put digits and
        // symbols on their letter keys).
        if (IsPad()) return;
        // Creating this file (e.g. over SSH) disables the tweak at next app launch.
        if ([[NSFileManager defaultManager] fileExistsAtPath:TPRKillSwitchFile]) {
            TPRLog(@"kill switch present, not hooking (uuid %@)", OwnUUID());
            return;
        }
        if (!NSClassFromString(@"TUIKBGraphSerialization"))
            dlopen("/System/Library/PrivateFrameworks/TextInputUI.framework/TextInputUI", RTLD_LAZY);

        SEL keyboardSel = NSSelectorFromString(@"keyboardForName:");
        SEL cacheSel = NSSelectorFromString(@"cacheIdentifierForKeyplaneNamed:");
        // All or nothing: a patched layout drawn from stale cached images is worse than no patch.
        if (!TargetMethod(@"TUIKBGraphSerialization", keyboardSel) || !TargetMethod(@"UIKeyboardLayoutStar", cacheSel)) {
            TPRLog(@"hooks NOT installed (uuid %@)", OwnUUID());
            return;
        }
        HookMethod(@"UIKeyboardLayoutStar", cacheSel, (IMP)hook_cacheIdentifierForKeyplaneNamed,
                   (IMP *)&orig_cacheIdentifierForKeyplaneNamed);
        HookMethod(@"TUIKBGraphSerialization", keyboardSel, (IMP)hook_keyboardForName, (IMP *)&orig_keyboardForName);
        if (TargetMethod(@"UIKBKeyplaneView", @selector(layoutSubviews)))
            HookMethod(@"UIKBKeyplaneView", @selector(layoutSubviews), (IMP)hook_keyplaneLayoutSubviews,
                       (IMP *)&orig_keyplaneLayoutSubviews);
        // iOS 26 lays out every iPhone keyboard with TextInputUI ("dynamic" keyboards). Earlier
        // versions do that for a few minority layouts, which stay Apple's.
        if ([NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){26, 0, 0}]) {
            BOOL sized = HookDynamicSizing();
            TPRSetDynamicKeyboardsUnsupported(sized ? nil : @"dynamic keyboard: no height hook on this iOS");
            if (!sized) TPRLog(@"height hook missing on this iOS");
            HookDynamicOrientation();
            if (TargetMethod(@"TUIKBKeyView", @selector(layoutSubviews)))
                HookMethod(@"TUIKBKeyView", @selector(layoutSubviews), (IMP)hook_keyViewLayoutSubviews,
                           (IMP *)&orig_keyViewLayoutSubviews);
        }
        SEL localizeSel = NSSelectorFromString(@"updateLocalizedKeysOnKeyplane:");
        if (TargetMethod(@"UIKeyboardLayoutStar", localizeSel))
            HookMethod(@"UIKeyboardLayoutStar", localizeSel, (IMP)hook_updateLocalizedKeys, (IMP *)&orig_updateLocalizedKeys);
        if (TargetMethod(@"UIKeyboardDockView", @selector(layoutSubviews)))
            HookMethod(@"UIKeyboardDockView", @selector(layoutSubviews), (IMP)hook_dockLayoutSubviews,
                       (IMP *)&orig_dockLayoutSubviews);
        // Optional: only the auto-capitalization option depends on these.
        for (NSArray *hook in @[ @[ @"setShift:", [NSValue valueWithPointer:(void *)hook_setShift], [NSValue valueWithPointer:&orig_setShift] ],
                                 @[ @"setAutoshift:", [NSValue valueWithPointer:(void *)hook_setAutoshift], [NSValue valueWithPointer:&orig_setAutoshift] ],
                                 @[ @"setKeyplaneName:", [NSValue valueWithPointer:(void *)hook_setKeyplaneName], [NSValue valueWithPointer:&orig_setKeyplaneName] ] ]) {
            SEL sel = NSSelectorFromString(hook[0]);
            if (TargetMethod(@"UIKeyboardLayoutStar", sel))
                HookMethod(@"UIKeyboardLayoutStar", sel, (IMP)[hook[1] pointerValue], (IMP *)[hook[2] pointerValue]);
        }
        // By executable name: NewTerm's forks have their own bundle IDs.
        if ([NSBundle.mainBundle.executablePath.lastPathComponent isEqualToString:@"NewTerm"] &&
            TargetMethod(@"NSLayoutConstraint", @selector(setConstant:))) {
            HookMethod(@"NSLayoutConstraint", @selector(setConstant:), (IMP)hook_setConstant, (IMP *)&orig_setConstant);
            TPRLog(@"NewTerm: ignoring sub-pixel SwiftUI size changes");
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, OnReloadNotification,
                                        (__bridge CFStringRef)TPRReloadNotification, NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
        TPRLog(@"hooks installed, config %@, uuid %@", [TPRConfig current].fingerprint, OwnUUID());
    }
}
