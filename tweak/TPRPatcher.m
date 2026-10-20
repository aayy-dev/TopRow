#import "TPRPatcher.h"
#import "TPRConfig.h"
#import "TPRTree.h"
#import "TPRKeyRows.h"

// How the keyboard graph is laid out (iOS 17/18 portrait iPhone, raw from the serializer):
//
//   [1] keyboard ─ KBshape = whole keyboard (375x216 design units)
//     [2] keyplane (Small-Letters, Capital-Letters, Numbers-And-Punctuation, ...)
//       [3] key layout ─ KBshape = whole keyboard (same object as the keyboard's)
//         [4] keyset        ─ [7] row ─ [8] keys (strings, no shapes yet)
//         [5] geometry set  ─ [7] row ─ UIKBShape per key, KBshape = row frame
//         [6] attribute set ─ [7] row ─ NSDictionary per key (popup-bias, ...)
//
// Rows in the keyset, geometry set and attribute set line up by index, and keys
// line up with shapes/attributes by index within a row. UIKeyboardLayoutStar
// later "elaborates" this into positioned keys. Shapes, rows and whole layouts
// are shared between keyplanes (and with the serializer's cache), so we only
// ever edit per-plane deep copies.
//
// The extra row is merged into the top row of the main key layout (keys,
// shapes and attributes prepended), placed one row-pitch above it; everything
// else in the plane moves down one pitch and the containers grow by one pitch.
// Keys keep Apple's sizes; the keyboard gets taller.

static const NSUInteger kCopyBudget = 8000;
static const int kMaxDepth = 24;

static id DeepCopy(id obj, NSMapTable *copies, NSUInteger *budget, int depth);

// Set while copying an iOS 26 dynamic keyboard (only under TPRPatchKeyboard's lock).
static BOOL gCopyingDynamic;

static NSMutableArray *DeepCopyArray(NSArray *array, NSMapTable *copies, NSUInteger *budget, int depth) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:array.count];
    for (id item in array) {
        id copy = DeepCopy(item, copies, budget, depth);
        if (!copy) return nil;
        [out addObject:copy];
    }
    return out;
}

// Copies trees, shapes and containers; shares immutable leaves (strings, numbers).
// `copies` maps original -> copy so objects shared inside a plane stay shared.
static id DeepCopy(id obj, NSMapTable *copies, NSUInteger *budget, int depth) {
    if (!obj) return nil;
    id done = [copies objectForKey:obj];
    if (done) return done;
    if (depth > kMaxDepth || *budget == 0) return nil;
    (*budget)--;

    if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]]) return obj;

    if (TPRIsShape(obj)) {
        id copy = [obj copy];
        if (!copy || copy == obj) return nil;
        [copies setObject:copy forKey:obj];
        return copy;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:[obj count]];
        for (id key in obj) {
            id value = DeepCopy(obj[key], copies, budget, depth + 1);
            if (!value) return nil;
            out[key] = value;
        }
        [copies setObject:out forKey:obj];
        return out;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = DeepCopyArray(obj, copies, budget, depth + 1);
        if (out) [copies setObject:out forKey:obj];
        return out;
    }
    if (!TPRIsTree(obj)) {
        // Anything else (sets, values, ...) is never mutated by the patch, so sharing it is safe.
#if TPR_SIMULATOR
        NSLog(@"[TopRow] sharing leaf of class %@", NSStringFromClass([obj class]));
#endif
        return obj;
    }

    id<TPRKBTree> copy = [obj copy];
    if (!copy || copy == obj) return nil;
    [copies setObject:copy forKey:obj];
    // -copy prefixes the name with a serial number; UIKit looks keyplanes and keys up by name.
    if (TPRName(obj)) [copy setName:TPRName(obj)];
    NSMutableDictionary *props = DeepCopy(TPRProperties(obj) ?: @{}, copies, budget, depth + 1);
    NSMutableArray *subtrees = DeepCopyArray(TPRSubtrees(obj) ?: @[], copies, budget, depth + 1);
    // iOS 26 (TextInputUI) treats a key with an empty subtrees array as having long-press
    // variants and reads the first one, so in dynamic keyboards nil stays nil.
    BOOL keepNil = gCopyingDynamic && !TPRSubtrees(obj);
    // Keyplanes arrive with a cache indexing their special keys by name (More-Key,
    // Shift-Key, currency signs, ...); UIKit relabels and hides keys through it, so it
    // must point at the copied keys rather than be dropped.
    id cache = [obj respondsToSelector:@selector(cache)] ? [obj cache] : nil;
    NSMutableDictionary *cacheCopy = [cache isKindOfClass:[NSDictionary class]]
        ? DeepCopy(cache, copies, budget, depth + 1) : [NSMutableDictionary dictionary];
    if (!props || !subtrees || !cacheCopy) return nil;
    [copy setProperties:props];
    [copy setSubtrees:keepNil ? nil : subtrees];
    [copy setCache:gCopyingDynamic && ![cache isKindOfClass:[NSDictionary class]] ? nil : cacheCopy];
    return copy;
}

static BOOL HasSetters(id node) {
    return [node respondsToSelector:@selector(setProperties:)] && [node respondsToSelector:@selector(setSubtrees:)] &&
           [node respondsToSelector:@selector(setName:)] && [node respondsToSelector:@selector(setCache:)];
}

// Collects every distinct shape reachable from `node`, noting which ones are
// key-layout frames (those grow instead of moving).
static void CollectShapes(id node, NSHashTable *shapes, NSHashTable *growing, int depth) {
    if (depth > kMaxDepth) return;
    if (TPRIsShape(node)) {
        [shapes addObject:node];
        return;
    }
    id shape = TPRShapeOf(node);
    if (shape) {
        [shapes addObject:shape];
        if (TPRType(node) == TPRNodeKeylayout) [growing addObject:shape];
    }
    for (id child in TPRSubtrees(node)) CollectShapes(child, shapes, growing, depth + 1);
}

static CGRect Offset(CGRect r, CGFloat dy) {
    // Zero rects mean "unset" (e.g. row paddedFrames); leave them alone.
    return CGRectEqualToRect(r, CGRectZero) ? r : CGRectOffset(r, 0, dy);
}

static TPRPlaneKind PlaneKind(id plane) {
    BOOL alphabetic = [plane respondsToSelector:@selector(isAlphabeticPlane)] && [(id<TPRKBTree>)plane isAlphabeticPlane];
    BOOL shifted = [plane respondsToSelector:@selector(isShiftKeyplane)] && [(id<TPRKBTree>)plane isShiftKeyplane];
    if (!alphabetic) return TPRPlaneNumbers;   // 123 and #+= (the latter is marked shifted too)
    return shifted ? TPRPlaneShifted : TPRPlaneLowercase;
}

// Letters get the row on top; on 123/#+= it goes under the stock digit row.
static NSUInteger InsertRowForPlane(TPRPlaneKind kind) {
    return kind == TPRPlaneNumbers ? 1 : 0;
}

// Main key layout: not a control-key layout; its keyset row `row` lines up with
// geometry row `row`, and there are at least two rows to measure the pitch.
static BOOL FindMainLayout(id plane, NSUInteger row, id *keyset, id *geometrySet, id *attributeSet) {
    for (id layout in TPRSubtrees(plane)) {
        if (TPRType(layout) != TPRNodeKeylayout || [TPRName(layout) containsString:@"Control"]) continue;
        id ks = TPRChildOfType(layout, TPRNodeKeyset), gs = TPRChildOfType(layout, TPRNodeGeometrySet);
        NSArray *keyRows = TPRSubtrees(ks), *geomRows = TPRSubtrees(gs);
        if (keyRows.count < MAX(2, row + 1) || geomRows.count < MAX(2, row + 1)) continue;
        NSUInteger n = TPRSubtrees(keyRows[row]).count;
        // A full-width key row (QWERTY / 123 rows have 10); pads have 3.
        if (n < 8 || n != TPRSubtrees(geomRows[row]).count) continue;
        *keyset = ks;
        *geometrySet = gs;
        *attributeSet = TPRChildOfType(layout, TPRNodeAttributeSet);
        return YES;
    }
    return NO;
}

// The row frame cut to where Apple's keys actually reach (their widest row): row frames
// can be wider than the keyboard (landscape "568x162" lists are 736 wide), and keys
// placed past Apple's last one end up off-screen.
static CGRect WithinKeys(CGRect rowFrame, id geometrySet) {
    CGRect span = CGRectNull;
    for (id list in TPRSubtrees(geometrySet))
        for (id shape in TPRSubtrees(list)) {
            CGRect f;
            if (TPRIsShape(shape) && TPRGetFrames(shape, &f, NULL) && f.size.width > 0) span = CGRectUnion(span, f);
        }
    CGFloat left = MAX(CGRectGetMinX(rowFrame), CGRectGetMinX(span)), right = MIN(CGRectGetMaxX(rowFrame), CGRectGetMaxX(span));
    if (CGRectIsNull(span) || right <= left) return rowFrame;
    rowFrame.origin.x = left;
    rowFrame.size.width = right - left;
    return rowFrame;
}

// Frames for `count` keys spread evenly across `rowFrame`, keeping the template
// key's gap and its frame-to-paddedFrame insets.
static void ComputedFrames(NSUInteger count, CGRect rowFrame, CGRect key0, CGRect key0Padded, CGFloat gap,
                           CGRect *frames, CGRect *padded) {
    CGFloat width = (rowFrame.size.width - gap * (count - 1)) / count;
    for (NSUInteger i = 0; i < count; i++) {
        frames[i] = CGRectMake(CGRectGetMinX(rowFrame) + i * (width + gap), key0.origin.y, width, key0.size.height);
        padded[i] = CGRectMake(frames[i].origin.x + (key0Padded.origin.x - key0.origin.x), key0Padded.origin.y,
                               width - (key0.size.width - key0Padded.size.width), key0Padded.size.height);
    }
}

// Adds the row above keyset row `row` of a deep-copied plane. Returns nil on
// success, else why not.
static NSString *PatchPlane(id plane, NSArray<NSString *> *labels, NSArray<NSString *> *hints, NSUInteger row,
                            NSString *fingerprint, CGFloat *pitchOut) {
    id keyset, geometrySet, attributeSet;
    if (!FindMainLayout(plane, row, &keyset, &geometrySet, &attributeSet)) return @"no usable key layout";

    NSArray *geomRows = TPRSubtrees(geometrySet);
    id keyRow = TPRSubtrees(keyset)[row];
    id geomRow = geomRows[row];
    CGRect row0, row1, target;
    if (!TPRGetFrames(geomRows[0], &row0, NULL) || !TPRGetFrames(geomRows[1], &row1, NULL) ||
        !TPRGetFrames(geomRow, &target, NULL))
        return @"row frames unreadable";
    CGFloat pitch = CGRectGetMinY(row1) - CGRectGetMinY(row0);
    if (pitch < 16 || pitch > 200) return [NSString stringWithFormat:@"row pitch %.1f out of range", pitch];
    CGFloat insertY = CGRectGetMinY(target);

    // 1. Make room: everything from the target row down moves one pitch; key layouts grow.
    NSHashTable *shapes = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSHashTable *growing = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    CollectShapes(plane, shapes, growing, 0);
    for (id shape in shapes) {
        CGRect f, p;
        if (!TPRGetFrames(shape, &f, &p)) return @"shape frame unreadable";
        if ([growing containsObject:shape]) {
            f.size.height += pitch;
            if (!CGRectEqualToRect(p, CGRectZero)) p.size.height += pitch;
        } else if (CGRectGetMinY(f) >= insertY - 0.5 && !CGRectEqualToRect(f, CGRectZero)) {
            f = Offset(f, pitch);
            p = Offset(p, pitch);
        } else {
            continue;
        }
        TPRSetFrames(shape, f, p);
    }

    // 2. New keys and shapes in the freed slot. With as many keys as the target row
    //    they mirror its columns; otherwise they're spread evenly across the row.
    NSArray *oldKeys = TPRSubtrees(keyRow), *oldShapes = TPRSubtrees(geomRow);
    NSUInteger count = labels.count;
    CGRect frames[count], padded[count];
    BOOL mirror = count == oldKeys.count;
    for (NSUInteger i = 0; i < count; i++) {
        if (!TPRGetFrames(oldShapes[mirror ? i : 0], &frames[i], &padded[i])) return @"donor geometry unreadable";
        frames[i] = Offset(frames[i], -pitch);
        padded[i] = Offset(padded[i], -pitch);
    }
    if (!mirror) {
        CGRect rowFrame, k1 = CGRectNull, unused;
        if (!TPRGetFrames(geomRow, &rowFrame, NULL)) return @"row frame unreadable";
        rowFrame = WithinKeys(rowFrame, geometrySet);
        CGFloat gap = 0;
        if (oldShapes.count > 1 && TPRGetFrames(oldShapes[1], &k1, &unused))
            gap = MIN(MAX(CGRectGetMinX(k1) - CGRectGetMaxX(Offset(frames[0], pitch)), 0), 40);
        ComputedFrames(count, rowFrame, frames[0], padded[0], gap, frames, padded);
        if (frames[0].size.width < 8) return @"keys too narrow";
    }
    NSUInteger rowTag = [labels componentsJoinedByString:@"\x1f"].hash;
    NSMutableArray *newKeys = [NSMutableArray array], *newShapes = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        id donorKey = oldKeys[mirror ? i : 0], donorShape = oldShapes[mirror ? i : 0];
        id<TPRKBTree> key = [donorKey copy];
        id shape = [donorShape copy];
        if (!key || key == donorKey || !shape || shape == donorShape) return @"donor key copy failed";
        TPRSetFrames(shape, frames[i], padded[i]);

        NSMutableDictionary *props = [TPRProperties(donorKey) mutableCopy];
        props[@"KBdisplayString"] = labels[i];
        props[@"KBrepresentedString"] = labels[i];
        // A plain key, whatever the donor was: the key under it may be a currency key
        // (display type 8, currency long-press variants) whose glyph UIKit localizes.
        props[@"KBdisplayType"] = @0;
        [props removeObjectForKey:@"variant-type"];
        // Symbol hint, drawn by our keyplane-view overlay (UIKit ignores this key).
        if (hints.count == count) props[@"TPRhint"] = hints[i];
        [key setProperties:props];
        // Name encodes the row's contents: UIKit caches key artwork by key name.
        [key setName:[NSString stringWithFormat:@"TopRow-%lx-Key-%lu", (unsigned long)rowTag, (unsigned long)i]];
        [key setCache:[NSMutableDictionary dictionary]];
        [newKeys addObject:key];
        [newShapes addObject:shape];
    }

    // 3. Merge: the target row now holds [new row..., old row...].
    [(id<TPRKBTree>)keyRow setSubtrees:[[newKeys arrayByAddingObjectsFromArray:oldKeys] mutableCopy]];
    [(id<TPRKBTree>)geomRow setSubtrees:[[newShapes arrayByAddingObjectsFromArray:oldShapes] mutableCopy]];
    NSArray *attrRows = TPRSubtrees(attributeSet);
    id attrRow = row < attrRows.count ? attrRows[row] : nil;
    NSArray *oldAttrs = TPRSubtrees(attrRow);
    if (oldAttrs.count == oldKeys.count && oldAttrs.count) {
        NSMutableArray *attrs = [NSMutableArray array];
        for (NSUInteger i = 0; i < count; i++) {
            // Edge keys keep their popup bias; middle keys take a middle key's attributes.
            NSDictionary *a = mirror ? oldAttrs[i] : i == 0 ? oldAttrs.firstObject
                            : i == count - 1 ? oldAttrs.lastObject : oldAttrs[oldAttrs.count / 2];
            [attrs addObject:[a mutableCopy]];
        }
        [(id<TPRKBTree>)attrRow setSubtrees:[[attrs arrayByAddingObjectsFromArray:oldAttrs] mutableCopy]];
    }
    // The merged row's frame spans both rows.
    CGRect rowFrame, rowPadded;
    if (TPRGetFrames(geomRow, &rowFrame, &rowPadded)) {
        rowFrame.origin.y -= pitch;
        rowFrame.size.height += pitch;
        TPRSetFrames(geomRow, rowFrame, rowPadded);
    }
    // UIKit keys rendered keyplane images by keyset/geometry-set names (not labels):
    // fold the config in so a changed row can't reuse stale artwork.
    for (id node in @[ keyset, geometrySet ])
        [(id<TPRKBTree>)node setName:[NSString stringWithFormat:@"%@-TPR%@", TPRName(node), fingerprint]];
    *pitchOut = pitch;
    return nil;
}

// ---- dynamic keyboards (iOS 26) ---------------------------------------------------------
//
// iOS 26 iPhone keyboards ("Dynamic-QWERTY-Small", KBdynamic = 1) carry no geometry. A
// keyplane's key layout lists its rows in row sets, one per keyboard type:
//
//   [2] keyplane
//     [3] key layout (KBdynamic, DynamicKeyset, per-type dicts)
//       [15] row set "..._Default" (KBRowSetVariantType 0)
//         [7] "Keylist.Row1.Layout"  ─ [8] padding, [7] keyset row ─ [8] keys, [8] padding
//         [7] "Keylist.Row2.Layout"  ...
//         [7] "Keylist.Row3.Layout"  (Shift, padding, keys, padding, Delete)
//         [4] "Space-Row-Small"
//       [15] row set "..._EmailAddress" / URL / Twitter / ... ─ [4] its own space row
//       [6] attribute set
//
// -[UIKBTree orderedRowsForType:] takes the Default row set's rows and lets a type's row
// set replace the last ones (its space row), and TextInputUI's TUIKeyplane builds one
// row of keys per entry, sizing keys by relative widths (row properties like
// "Shift-Key" = "1.3") and rows by -heightMultiplierForRowNumber:. So the extra row is a
// new row layout in the Default row set, built like Apple's first row, and every
// keyboard type inherits it. The keyboard height comes from +[TUIKeyplane
// sizeFromScreenTraits:layout:layoutClass:] (Tweak.m makes room for the extra row).

BOOL TPRIsDynamicKeyboard(id keyboard) {
    return [TPRProperties(keyboard)[@"KBdynamic"] boolValue];
}

// Set once, from the dylib constructor.
static NSString *gDynamicUnsupported = @"dynamic keyboard before iOS 26";

void TPRSetDynamicKeyboardsUnsupported(NSString *reason) {
    gDynamicUnsupported = [reason copy];
}

static NSInteger RowSetType(id node) {
    id type = TPRProperties(node)[@"KBRowSetVariantType"];
    return [type respondsToSelector:@selector(integerValue)] ? [type integerValue] : -1;
}

// The plane's character key layout and its Default row set.
static BOOL FindDynamicRowSet(id plane, id *layoutOut, id *rowSetOut) {
    for (id layout in TPRSubtrees(plane)) {
        if (TPRType(layout) != TPRNodeKeylayout || ![TPRProperties(layout)[@"KBdynamic"] boolValue]) continue;
        id first = nil, zero = nil;
        for (id child in TPRSubtrees(layout)) {
            if (TPRType(child) != 15) continue;
            if (!first) first = child;
            if (RowSetType(child) == 0 && !zero) zero = child;
        }
        id rowSet = zero ?: first;
        if (!rowSet) continue;
        *layoutOut = layout;
        *rowSetOut = rowSet;
        return YES;
    }
    return NO;
}

// The keyset row (the character keys) inside a row layout, if it has one.
static id DynamicKeysetRow(id rowLayout) {
    for (id child in TPRSubtrees(rowLayout))
        if (TPRType(child) == TPRNodeList) return child;
    return nil;
}

// Dynamic keyboards (iOS 26) have no frames to place keys with: a row's keys share its
// width by relative units. -[TUIKeyplane multiplierForKey:withProperties:] looks a key up
// in its row layout's properties by name, then by represented string, then (names like
// "2_Padding-Left") by the name past the prefix; a value naming another property
// ("Padding-Right" = "Padding-Left") is looked up once more; 1 when there's none. The keys
// of a keyset row inside a row layout all take the key layout's value for the keyset row's
// name from "Row" on, when it has one ("Row3" = "1.4" on the 123 pages).

static NSString *DynamicWidthProperty(id key, NSDictionary *props) {
    NSString *name = TPRName(key), *typed = TPRProperties(key)[@"KBrepresentedString"];
    if (name && props[name]) return name;
    if ([typed isKindOfClass:[NSString class]] && props[typed]) return typed;
    if ([name rangeOfString:@"_"].location == 1 && props[[name substringFromIndex:2]]) return [name substringFromIndex:2];
    return nil;
}

static double DynamicWidth(id key, NSDictionary *props) {
    NSString *prop = DynamicWidthProperty(key, props);
    id value = prop ? props[prop] : nil;
    if (value && props[value]) value = props[value];
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 1;
}

static NSString *KeysetWidthProperty(id keysetRow, NSDictionary *layoutProps) {
    NSString *name = TPRName(keysetRow);
    NSRange row = [name rangeOfString:@"Row"];
    if (row.location != NSNotFound && layoutProps[[name substringFromIndex:row.location]]) return [name substringFromIndex:row.location];
    if (name && layoutProps[name]) return name;
    return row.location != NSNotFound ? [name substringFromIndex:row.location] : name;
}

static BOOL IsPaddingKey(id key) {
    return TPRType(key) == TPRNodeKey && [TPRProperties(key)[@"KBrepresentedString"] hasPrefix:@"Padding-"];
}

// A key layout can override a row's properties by row number ("Rowset.Row4",
// "Rowset.EmailAddress.Row4"; numbered from 1). After a row is inserted at index `row`, the
// rows below it are one further down. (No iPhone layout TopRow patches on iOS 26.0-26.3 has any.)
static NSMutableDictionary *RenumberRowOverrides(NSMutableDictionary *props, NSUInteger row) {
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^(Rowset\\.(?:[^.]+\\.)?Row)(\\d+)$"
                                                                             options:0 error:NULL];
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:props.count];
    for (NSString *key in props) {
        NSTextCheckingResult *match = [key isKindOfClass:[NSString class]]
            ? [pattern firstMatchInString:key options:0 range:NSMakeRange(0, key.length)] : nil;
        NSInteger number = match ? [key substringWithRange:[match rangeAtIndex:2]].integerValue : 0;
        NSString *renumbered = match && number > (NSInteger)row
            ? [NSString stringWithFormat:@"%@%ld", [key substringWithRange:[match rangeAtIndex:1]], (long)number + 1] : key;
        out[renumbered] = props[key];
    }
    return out;
}

static NSString *PatchDynamicPlane(id plane, NSArray<NSString *> *labels, NSArray<NSString *> *hints, NSUInteger row,
                                   NSString *fingerprint) {
    id layout, rowSet;
    if (!FindDynamicRowSet(plane, &layout, &rowSet)) return @"no dynamic row set";
    NSArray *rows = TPRSubtrees(rowSet);
    if (rows.count < MAX(3, row + 1)) return @"too few rows";
    id template = rows[0];   // Apple's first row spans the keyboard (no edge padding)
    id keysetRow = DynamicKeysetRow(template);
    NSArray *oldKeys = TPRSubtrees(keysetRow);
    if (TPRType(template) != TPRNodeList || oldKeys.count < 8) return @"no full-width key row";
    for (id key in oldKeys)
        if (TPRType(key) != TPRNodeKey) return @"unexpected key row";

    // The units Apple's row fills: its keyset row, keys beside it (QWERTZ's Ü) and paddings.
    // The new row has to fill the same, or TextInputUI can't lay it out and its keys end up
    // with no width.
    NSMutableDictionary *layoutProps = [TPRProperties(layout) mutableCopy] ?: [NSMutableDictionary dictionary];
    NSDictionary *templateProps = TPRProperties(template) ?: @{};
    id shared = layoutProps[KeysetWidthProperty(keysetRow, layoutProps) ?: @""];
    double keyUnits = 0, otherUnits = 0;
    BOOL otherKeys = NO;
    for (id key in oldKeys)
        keyUnits += [shared respondsToSelector:@selector(doubleValue)] ? [shared doubleValue] : DynamicWidth(key, templateProps);
    for (id child in TPRSubtrees(template)) {
        if (child == keysetRow || TPRType(child) != TPRNodeKey) continue;
        otherUnits += DynamicWidth(child, templateProps);
        if (!IsPaddingKey(child)) otherKeys = YES;
    }
    if (keyUnits <= 0) return @"key row has no width";

    NSUInteger count = labels.count;
    NSUInteger rowTag = [labels componentsJoinedByString:@"\x1f"].hash;
    NSMutableArray *newKeys = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        // Same position in Apple's row where there is one (its display corner, popup side).
        id donor = oldKeys[MIN(count == oldKeys.count ? i : i * oldKeys.count / count, oldKeys.count - 1)];
        id<TPRKBTree> key = [donor copy];
        if (!key || key == donor) return @"donor key copy failed";
        NSMutableDictionary *props = [TPRProperties(donor) mutableCopy];
        props[@"KBdisplayString"] = labels[i];
        props[@"KBrepresentedString"] = labels[i];
        props[@"KBdisplayType"] = @0;   // a plain key, even under a currency key
        [props removeObjectForKey:@"variant-type"];
        [props removeObjectForKey:@"KBlocalizationKey"];
        [props removeObjectForKey:@"KBshape"];
        if (hints.count == count) props[@"TPRhint"] = hints[i];
        [key setProperties:props];
        [key setName:[NSString stringWithFormat:@"TopRow-%lx-Key-%lu", (unsigned long)rowTag, (unsigned long)i]];
        [key setCache:[NSMutableDictionary dictionary]];
        [key setSubtrees:nil];   // no long-press list (an empty one crashes on touch)
        [newKeys addObject:key];
    }

    id<TPRKBTree> newKeyset = [keysetRow copy];
    id<TPRKBTree> newRow = [template copy];
    if (!newKeyset || newKeyset == keysetRow || !newRow || newRow == template) return @"row copy failed";
    NSString *tag = [NSString stringWithFormat:@"TopRow-%@", fingerprint];
    NSMutableDictionary *keysetProps = [TPRProperties(keysetRow) mutableCopy] ?: [NSMutableDictionary dictionary];
    if (keysetProps[@"Alias"]) keysetProps[@"Alias"] = [NSString stringWithFormat:@"%@_Keyset", tag];
    [newKeyset setProperties:keysetProps];
    [newKeyset setName:[NSString stringWithFormat:@"%@_Keyset", tag]];
    [newKeyset setSubtrees:newKeys];
    [newKeyset setCache:[NSMutableDictionary dictionary]];

    // The row layout: Apple's padding keys around the new keys. Apple's other keys stay out:
    // a key in two rows is taken for one spanning both.
    NSMutableArray *rowItems = [NSMutableArray array];
    for (id child in TPRSubtrees(template))
        if (child == keysetRow || IsPaddingKey(child)) [rowItems addObject:child == keysetRow ? newKeyset : child];
    NSMutableDictionary *rowProps = [templateProps mutableCopy];
    if (rowProps[@"Alias"]) rowProps[@"Alias"] = [NSString stringWithFormat:@"%@_Row", tag];
    // As many keys as Apple's keyset row (and nothing beside it): its columns. Otherwise the
    // keys share the whole row.
    BOOL mirror = count == oldKeys.count && !otherKeys;
    if (!mirror)
        for (id child in rowItems)
            if (child != newKeyset)
                rowProps[DynamicWidthProperty(child, rowProps) ?: TPRProperties(child)[@"KBrepresentedString"]] = @"0";
    layoutProps[KeysetWidthProperty(newKeyset, layoutProps)] =
        [NSString stringWithFormat:@"%.6f", (mirror ? keyUnits : keyUnits + otherUnits) / count];
    [newRow setProperties:rowProps];
    [newRow setName:[NSString stringWithFormat:@"%@_Row", tag]];
    [newRow setSubtrees:rowItems];
    [newRow setCache:[NSMutableDictionary dictionary]];

    // The layout's attribute set has one entry per row (UIKit walks them together): give
    // the new row an empty one, like Apple's first row has.
    id attributeSet = TPRChildOfType(layout, TPRNodeAttributeSet);
    NSArray *attrRows = TPRSubtrees(attributeSet);
    if (attrRows.count != rows.count || TPRType(attrRows[0]) != TPRNodeList) return @"attribute rows don't match";
    id<TPRKBTree> emptyAttrs = [attrRows[0] copy];
    if (!emptyAttrs || emptyAttrs == attrRows[0]) return @"attribute copy failed";
    [emptyAttrs setName:@"Empty_Attribute_List"];
    [emptyAttrs setProperties:[NSMutableDictionary dictionary]];
    // Empty like Apple's (nil subtrees stay nil, see DeepCopy).
    [emptyAttrs setSubtrees:TPRSubtrees(attrRows[0]).count ? [NSMutableArray array] : [TPRSubtrees(attrRows[0]) mutableCopy]];
    NSMutableArray *newAttrs = [attrRows mutableCopy];
    [newAttrs insertObject:emptyAttrs atIndex:row];

    NSMutableArray *newRows = [rows mutableCopy];
    [newRows insertObject:newRow atIndex:row];
    [(id<TPRKBTree>)rowSet setSubtrees:newRows];
    [(id<TPRKBTree>)attributeSet setSubtrees:newAttrs];
    [(id<TPRKBTree>)layout setProperties:RenumberRowOverrides(layoutProps, row)];
    return nil;
}

// A keyboard's planes share one height on iOS 26 (it's sized per layout, not per plane), so
// a plane without the extra row (none set for it, or one that didn't fit) would have its rows
// stretched into the room the row takes elsewhere. It gets an empty band on top instead: a
// row of Apple's padding keys alone, filling the row's units (no keys to draw or press).
static NSString *InsertDynamicSpacer(id plane, NSString *fingerprint) {
    id layout, rowSet;
    if (!FindDynamicRowSet(plane, &layout, &rowSet)) return @"no dynamic row set";
    NSArray *rows = TPRSubtrees(rowSet);
    id template = rows.count >= 3 ? rows[0] : nil;
    id keysetRow = DynamicKeysetRow(template);
    NSArray *oldKeys = TPRSubtrees(keysetRow);
    if (TPRType(template) != TPRNodeList || !oldKeys.count) return @"no key row";
    NSDictionary *layoutProps = TPRProperties(layout) ?: @{}, *templateProps = TPRProperties(template) ?: @{};
    id shared = layoutProps[KeysetWidthProperty(keysetRow, layoutProps) ?: @""];
    double units = 0;
    for (id key in oldKeys)
        units += [shared respondsToSelector:@selector(doubleValue)] ? [shared doubleValue] : DynamicWidth(key, templateProps);
    for (id child in TPRSubtrees(template))
        if (child != keysetRow && TPRType(child) == TPRNodeKey) units += DynamicWidth(child, templateProps);
    NSMutableArray *rowItems = [NSMutableArray array];
    NSMutableDictionary *rowProps = [templateProps mutableCopy];
    for (id child in TPRSubtrees(template))
        if (IsPaddingKey(child)) [rowItems addObject:child];
    if (!rowItems.count) return @"no padding keys";
    for (id pad in rowItems)
        rowProps[DynamicWidthProperty(pad, rowProps) ?: TPRProperties(pad)[@"KBrepresentedString"]] =
            [NSString stringWithFormat:@"%.6f", units / rowItems.count];
    NSString *name = [NSString stringWithFormat:@"TopRow-%@_Spacer", fingerprint];
    if (rowProps[@"Alias"]) rowProps[@"Alias"] = name;
    id<TPRKBTree> newRow = [template copy];
    if (!newRow || newRow == template) return @"spacer copy failed";
    [newRow setProperties:rowProps];
    [newRow setName:name];
    [newRow setSubtrees:rowItems];
    [newRow setCache:[NSMutableDictionary dictionary]];

    id attributeSet = TPRChildOfType(layout, TPRNodeAttributeSet);
    NSArray *attrRows = TPRSubtrees(attributeSet);
    if (attrRows.count != rows.count || TPRType(attrRows[0]) != TPRNodeList) return @"attribute rows don't match";
    id<TPRKBTree> emptyAttrs = [attrRows[0] copy];
    if (!emptyAttrs || emptyAttrs == attrRows[0]) return @"attribute copy failed";
    [emptyAttrs setName:@"Empty_Attribute_List"];
    [emptyAttrs setProperties:[NSMutableDictionary dictionary]];
    [emptyAttrs setSubtrees:TPRSubtrees(attrRows[0]).count ? [NSMutableArray array] : [TPRSubtrees(attrRows[0]) mutableCopy]];
    NSMutableArray *newAttrs = [attrRows mutableCopy], *newRows = [rows mutableCopy];
    [newAttrs insertObject:emptyAttrs atIndex:0];
    [newRows insertObject:newRow atIndex:0];
    [(id<TPRKBTree>)rowSet setSubtrees:newRows];
    [(id<TPRKBTree>)attributeSet setSubtrees:newAttrs];
    [(id<TPRKBTree>)layout setProperties:RenumberRowOverrides([layoutProps mutableCopy], 0)];
    return nil;
}

// ---- custom keys ---------------------------------------------------------------------
//
// The Keys page replaces whole rows of Apple's keys. A row is only touched when the plane
// is the US layout TPRKeyRows.h describes (all three rows match), so other languages and
// the email/URL 123 pages stay as they are. Keys the user left in their row keep Apple's
// key (its accents on long-press, the localized currency sign, "back to letters" after
// the apostrophe); new ones are plain keys built from a key in the same row. A row with a
// different number of keys keeps Apple's key width while it fits, centered where Apple's
// row was, and shrinks evenly when it doesn't (within the row, or between Shift and Delete).

static TPRKeyPlane KeyPlaneOf(id plane) {
    BOOL alphabetic = [plane respondsToSelector:@selector(isAlphabeticPlane)] && [(id<TPRKBTree>)plane isAlphabeticPlane];
    BOOL shifted = [plane respondsToSelector:@selector(isShiftKeyplane)] && [(id<TPRKBTree>)plane isShiftKeyplane];
    if (alphabetic) return shifted ? TPRKeyPlaneShifted : TPRKeyPlaneLetters;
    return shifted ? TPRKeyPlaneSymbols : TPRKeyPlaneNumbers;   // #+= is the shifted non-letters plane
}

static BOOL IsTopRowKey(id key) {
    return [TPRName(key) hasPrefix:@"TopRow-"];
}

// The plane's character-key layout, if its rows line up with geometry (and attributes).
static BOOL FindKeyLayout(id plane, id *keyset, id *geometrySet, id *attributeSet) {
    for (id layout in TPRSubtrees(plane)) {
        if (TPRType(layout) != TPRNodeKeylayout || [TPRName(layout) containsString:@"Control"]) continue;
        id ks = TPRChildOfType(layout, TPRNodeKeyset), gs = TPRChildOfType(layout, TPRNodeGeometrySet);
        if (TPRSubtrees(ks).count < TPRKeyRowCount || TPRSubtrees(ks).count != TPRSubtrees(gs).count) continue;
        *keyset = ks;
        *geometrySet = gs;
        *attributeSet = TPRChildOfType(layout, TPRNodeAttributeSet);
        return YES;
    }
    return NO;
}

// Apple's keys in a row (TopRow's merged-in keys left out).
static NSArray *StockKeys(id keyRow) {
    NSMutableArray *keys = [NSMutableArray array];
    for (id key in TPRSubtrees(keyRow))
        if (!IsTopRowKey(key)) [keys addObject:key];
    return keys;
}

// YES if every row of the plane is Apple's US row for that kind of plane.
static BOOL IsStockKeyPlane(id plane, TPRKeyPlane kind) {
    id keyset, geometrySet, attributeSet;
    if (!FindKeyLayout(plane, &keyset, &geometrySet, &attributeSet) || TPRSubtrees(keyset).count != TPRKeyRowCount) return NO;
    for (NSUInteger row = 0; row < TPRKeyRowCount; row++) {
        NSMutableArray *typed = [NSMutableArray array];
        for (id key in StockKeys(TPRSubtrees(keyset)[row])) {
            id represented = TPRProperties(key)[@"KBrepresentedString"];
            if (![represented isKindOfClass:[NSString class]]) return NO;
            [typed addObject:represented];
        }
        if (![typed isEqualToArray:TPRSplitKeys(TPRStockKeySignature(kind, row))]) return NO;
    }
    return YES;
}

// Frames for `count` keys in the space Apple's row may use. `obstacles` are other keys'
// frames in the plane (Shift, Delete) that the row has to stay clear of.
static BOOL RowFrames(NSArray *stockShapes, CGRect rowFrame, NSArray<NSValue *> *obstacles, NSUInteger count,
                      CGRect *frames, CGRect *padded) {
    CGRect f0, p0, minF = CGRectNull;
    if (!TPRGetFrames(stockShapes.firstObject, &f0, &p0)) return NO;
    for (id shape in stockShapes) {
        CGRect f;
        if (!TPRGetFrames(shape, &f, NULL)) return NO;
        minF = CGRectUnion(minF, f);
    }
    // Free space: the row's frame, cut back to Apple's margin next to any key beside the row.
    CGFloat left = CGRectGetMinX(rowFrame), right = CGRectGetMaxX(rowFrame);
    for (NSValue *value in obstacles) {
        CGRect o = value.CGRectValue;
        if (CGRectGetMaxY(o) <= CGRectGetMinY(f0) + 0.5 || CGRectGetMinY(o) >= CGRectGetMaxY(f0) - 0.5) continue;
        if (CGRectGetMaxX(o) <= CGRectGetMinX(minF) + 0.5) left = MAX(left, CGRectGetMinX(minF));
        else if (CGRectGetMinX(o) >= CGRectGetMaxX(minF) - 0.5) right = MIN(right, CGRectGetMaxX(minF));
    }
    CGFloat width = MIN(f0.size.width, (right - left) / count);
    if (width < 8) return NO;
    CGFloat total = width * count;
    CGFloat start = MIN(MAX(CGRectGetMidX(minF) - total / 2, left), right - total);
    CGFloat insetX = p0.origin.x - f0.origin.x, insetW = f0.size.width - p0.size.width;
    for (NSUInteger i = 0; i < count; i++) {
        frames[i] = CGRectMake(start + i * width, f0.origin.y, width, f0.size.height);
        padded[i] = CGRectMake(frames[i].origin.x + insetX, p0.origin.y, MAX(width - insetW, 1), p0.size.height);
    }
    return YES;
}

// A key's attributes at position i of n: Apple's edge keys bias their popups inward.
static NSMutableDictionary *PositionAttributes(NSArray *stockAttrs, NSUInteger i, NSUInteger n) {
    NSDictionary *a = i == 0 ? stockAttrs.firstObject : i == n - 1 ? stockAttrs.lastObject : stockAttrs[stockAttrs.count / 2];
    NSMutableDictionary *out = [a isKindOfClass:[NSDictionary class]] ? [a mutableCopy] : [NSMutableDictionary dictionary];
    [out removeObjectForKey:@"more-after"];   // that belongs to a key (the apostrophe), not a position
    return out;
}

// Replaces Apple's keys in `row` of a copied plane with `labels`. Nothing is changed unless
// it all works. Returns nil on success, else why not; *removed collects keys taken out.
static NSString *CustomizeRow(id plane, id keyset, id geometrySet, id attributeSet, NSUInteger row, TPRKeyPlane kind,
                              NSArray<NSString *> *labels, NSHashTable *removed) {
    id keyRow = TPRSubtrees(keyset)[row], geomRow = TPRSubtrees(geometrySet)[row];
    NSArray *allKeys = TPRSubtrees(keyRow), *allShapes = TPRSubtrees(geomRow);
    if (allKeys.count != allShapes.count) return @"keys and shapes differ";
    NSUInteger top = 0;   // TopRow's own keys come first in the row they were merged into
    while (top < allKeys.count && IsTopRowKey(allKeys[top])) top++;
    NSArray *stockKeys = [allKeys subarrayWithRange:NSMakeRange(top, allKeys.count - top)];
    NSArray *stockShapes = [allShapes subarrayWithRange:NSMakeRange(top, allShapes.count - top)];
    NSArray<NSString *> *defaults = TPRSplitKeys(TPRStockKeyRow(kind, row));
    if (!stockKeys.count || stockKeys.count != defaults.count) return @"unexpected row";

    id attrRow = row < TPRSubtrees(attributeSet).count ? TPRSubtrees(attributeSet)[row] : nil;
    NSArray *allAttrs = TPRSubtrees(attrRow);
    BOOL hasAttrs = allAttrs.count == allKeys.count;
    NSArray *stockAttrs = hasAttrs ? [allAttrs subarrayWithRange:NSMakeRange(top, allAttrs.count - top)] : nil;

    // Keys elsewhere in the plane that sit level with this row (Shift, Delete).
    NSMutableArray<NSValue *> *obstacles = [NSMutableArray array];
    for (id layout in TPRSubtrees(plane)) {
        id gs = TPRChildOfType(layout, TPRNodeGeometrySet);
        if (TPRType(layout) != TPRNodeKeylayout || gs == geometrySet) continue;
        for (id list in TPRSubtrees(gs))
            for (id shape in TPRSubtrees(list)) {
                CGRect f;
                if (TPRIsShape(shape) && TPRGetFrames(shape, &f, NULL)) [obstacles addObject:[NSValue valueWithCGRect:f]];
            }
    }
    CGRect rowFrame;
    if (!TPRGetFrames(geomRow, &rowFrame, NULL)) return @"row frame unreadable";
    rowFrame = WithinKeys(rowFrame, geometrySet);
    NSUInteger count = labels.count;
    CGRect frames[count], padded[count];
    if (!RowFrames(stockShapes, rowFrame, obstacles, count, frames, padded)) return @"keys don't fit";

    // Small-Letters planes label lowercase keys in capitals (the small-display plane is
    // the lowercase-looking one); new keys follow whatever the row does.
    BOOL capitalDisplay = NO;
    for (id key in stockKeys) {
        NSString *shown = TPRProperties(key)[@"KBdisplayString"], *typed = TPRProperties(key)[@"KBrepresentedString"];
        if ([shown isKindOfClass:[NSString class]] && [typed isKindOfClass:[NSString class]] &&
            ![shown isEqualToString:typed] && [shown isEqualToString:typed.uppercaseString])
            capitalDisplay = YES;
    }

    id donor = stockKeys[stockKeys.count / 2];
    NSUInteger rowTag = [labels componentsJoinedByString:@"\x1f"].hash;
    NSMutableArray *newKeys = [NSMutableArray array], *newShapes = [NSMutableArray array], *newAttrs = [NSMutableArray array];
    NSHashTable *used = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger stock = [defaults indexOfObject:labels[i]];
        id<TPRKBTree> key;
        if (stock != NSNotFound && ![used containsObject:stockKeys[stock]]) {
            key = stockKeys[stock];   // Apple's own key, moved
            [used addObject:key];
        } else {
            id source = stock != NSNotFound ? stockKeys[stock] : donor;
            key = [source copy];
            if (!key || key == source) return @"key copy failed";
            NSMutableDictionary *props = [TPRProperties(source) mutableCopy];
            if (stock == NSNotFound) {
                props[@"KBdisplayString"] = capitalDisplay ? labels[i].uppercaseString : labels[i];
                props[@"KBrepresentedString"] = labels[i];
                // A plain key, whatever the donor was (it may be a localized currency key).
                props[@"KBdisplayType"] = @0;
                [props removeObjectForKey:@"variant-type"];
                [props removeObjectForKey:@"KBlocalizationKey"];
            }
            [key setProperties:props];
            // Name encodes the row's contents: UIKit caches key artwork by key name.
            [key setName:[NSString stringWithFormat:@"TPRKey-%lx-%ld-%lu-%lu", (unsigned long)rowTag, (long)kind,
                          (unsigned long)row, (unsigned long)i]];
            [key setCache:[NSMutableDictionary dictionary]];
        }
        id shape = [stockShapes[stock != NSNotFound ? stock : stockShapes.count / 2] copy];
        if (!shape) return @"shape copy failed";
        TPRSetFrames(shape, frames[i], padded[i]);
        [newKeys addObject:key];
        [newShapes addObject:shape];
        if (hasAttrs) {
            NSMutableDictionary *attrs = PositionAttributes(stockAttrs, i, count);
            id own = stock != NSNotFound ? stockAttrs[stock] : nil;
            if ([own isKindOfClass:[NSDictionary class]] && own[@"more-after"]) attrs[@"more-after"] = own[@"more-after"];
            [newAttrs addObject:attrs];
        }
    }
    for (id key in stockKeys)
        if (![used containsObject:key]) [removed addObject:key];

    NSRange topRange = NSMakeRange(0, top);
    [(id<TPRKBTree>)keyRow setSubtrees:[[[allKeys subarrayWithRange:topRange] arrayByAddingObjectsFromArray:newKeys] mutableCopy]];
    [(id<TPRKBTree>)geomRow setSubtrees:[[[allShapes subarrayWithRange:topRange] arrayByAddingObjectsFromArray:newShapes] mutableCopy]];
    if (hasAttrs)
        [(id<TPRKBTree>)attrRow setSubtrees:[[[allAttrs subarrayWithRange:topRange] arrayByAddingObjectsFromArray:newAttrs] mutableCopy]];
    return nil;
}

// UIKit finds special keys (currency signs, ...) through the keyplane's cache; drop the
// entries for keys a custom row took out.
static void PruneKeyCache(id plane, NSHashTable *removed) {
    if (!removed.count || ![plane respondsToSelector:@selector(cache)]) return;
    NSMutableDictionary *cache = [[(id<TPRKBTree>)plane cache] mutableCopy];
    for (id name in cache.allKeys) {
        id value = cache[name];
        if ([removed containsObject:value]) {
            [cache removeObjectForKey:name];
        } else if ([value isKindOfClass:[NSArray class]]) {
            NSMutableArray *kept = [NSMutableArray array];
            for (id item in value)
                if (![removed containsObject:item]) [kept addObject:item];
            cache[name] = kept;
        }
    }
    [(id<TPRKBTree>)plane setCache:cache];
}

// Apple's three character rows of a dynamic plane, as indexes into its Default row set:
// row layouts holding a keyset row, TopRow's own row left out.
static NSArray<NSNumber *> *DynamicCharacterRows(id rowSet) {
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *all = TPRSubtrees(rowSet);
    for (NSUInteger i = 0; i < all.count; i++)
        if (TPRType(all[i]) == TPRNodeList && ![TPRName(all[i]) hasPrefix:@"TopRow-"] && DynamicKeysetRow(all[i]))
            [rows addObject:@(i)];
    return rows;
}

static BOOL IsStockDynamicPlane(id plane, TPRKeyPlane kind) {
    id layout, rowSet;
    if (!FindDynamicRowSet(plane, &layout, &rowSet)) return NO;
    NSArray<NSNumber *> *rows = DynamicCharacterRows(rowSet);
    if (rows.count != TPRKeyRowCount) return NO;
    for (NSUInteger row = 0; row < TPRKeyRowCount; row++) {
        NSMutableArray *typed = [NSMutableArray array];
        for (id key in TPRSubtrees(DynamicKeysetRow(TPRSubtrees(rowSet)[rows[row].unsignedIntegerValue]))) {
            id represented = TPRProperties(key)[@"KBrepresentedString"];
            if (TPRType(key) != TPRNodeKey || ![represented isKindOfClass:[NSString class]]) return NO;
            [typed addObject:represented];
        }
        if (![typed isEqualToArray:TPRSplitKeys(TPRStockKeySignature(kind, row))]) return NO;
    }
    return YES;
}

// CustomizeRow for a dynamic plane: `rowLayout` is Apple's row (padding keys around a keyset
// row, maybe Shift and Delete outside them), `attrRow` its entry in the attribute set. The
// row keeps its total units: keys keep Apple's width while they fit between the paddings,
// centered by them, and share that space evenly (no padding) when they don't.
static NSString *CustomizeDynamicRow(id layout, id rowLayout, id attrRow, NSUInteger row, TPRKeyPlane kind,
                                     NSArray<NSString *> *labels, NSHashTable *removed) {
    id keysetRow = DynamicKeysetRow(rowLayout);
    NSArray *children = TPRSubtrees(rowLayout), *stockKeys = TPRSubtrees(keysetRow);
    NSArray<NSString *> *defaults = TPRSplitKeys(TPRStockKeyRow(kind, row));
    if (!stockKeys.count || stockKeys.count != defaults.count) return @"unexpected row";
    NSUInteger at = [children indexOfObjectIdenticalTo:keysetRow];
    if (at == 0 || at + 1 >= children.count || !IsPaddingKey(children[at - 1]) || !IsPaddingKey(children[at + 1]))
        return @"no padding around the keys";

    // Units Apple's keys and the paddings next to them take.
    NSMutableDictionary *layoutProps = [TPRProperties(layout) mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *rowProps = [TPRProperties(rowLayout) mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *keysProp = KeysetWidthProperty(keysetRow, layoutProps);
    if (!keysProp) return @"keyset row has no name";
    id shared = layoutProps[keysProp];
    double keyWidth = [shared respondsToSelector:@selector(doubleValue)] ? [shared doubleValue] : DynamicWidth(stockKeys[0], rowProps);
    if (!shared)
        for (id key in stockKeys)
            if (fabs(DynamicWidth(key, rowProps) - keyWidth) > 0.001) return @"uneven keys";
    double space = keyWidth * stockKeys.count + DynamicWidth(children[at - 1], rowProps) + DynamicWidth(children[at + 1], rowProps);
    NSUInteger count = labels.count;
    double width = MIN(keyWidth, space / count), padding = MAX((space - width * count) / 2, 0);
    if (width < 0.2) return @"keys don't fit";

    // Small-Letters planes label lowercase keys in capitals (the small-display plane is
    // the lowercase-looking one); new keys follow whatever the row does.
    BOOL capitalDisplay = NO;
    for (id key in stockKeys) {
        NSString *shown = TPRProperties(key)[@"KBdisplayString"], *typed = TPRProperties(key)[@"KBrepresentedString"];
        if ([shown isKindOfClass:[NSString class]] && [typed isKindOfClass:[NSString class]] &&
            ![shown isEqualToString:typed] && [shown isEqualToString:typed.uppercaseString])
            capitalDisplay = YES;
    }

    // Per-key attributes ("more-after" on the apostrophe) sit in a list at the keyset row's
    // position in the row's attribute list; UIKit pairs them with the keys by index.
    id attrList = at < TPRSubtrees(attrRow).count ? TPRSubtrees(attrRow)[at] : nil;
    NSArray *stockAttrs = TPRType(attrList) == TPRNodeList ? TPRSubtrees(attrList) : nil;
    BOOL hasAttrs = stockAttrs.count == stockKeys.count;

    NSUInteger rowTag = [labels componentsJoinedByString:@"\x1f"].hash;
    NSMutableArray *newKeys = [NSMutableArray array], *newAttrs = [NSMutableArray array];
    NSHashTable *used = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger stock = [defaults indexOfObject:labels[i]];
        id<TPRKBTree> key;
        if (stock != NSNotFound && ![used containsObject:stockKeys[stock]]) {
            key = stockKeys[stock];   // Apple's own key, moved
            [used addObject:key];
        } else {
            // A key from the same part of Apple's row (its display corner).
            id source = stock != NSNotFound ? stockKeys[stock] : stockKeys[MIN(i * stockKeys.count / count, stockKeys.count - 1)];
            key = [source copy];
            if (!key || key == source) return @"key copy failed";
            NSMutableDictionary *props = [TPRProperties(source) mutableCopy];
            if (stock == NSNotFound) {
                props[@"KBdisplayString"] = capitalDisplay ? labels[i].uppercaseString : labels[i];
                props[@"KBrepresentedString"] = labels[i];
                // A plain key, whatever the donor was (it may be a localized currency key).
                props[@"KBdisplayType"] = @0;
                [props removeObjectForKey:@"variant-type"];
                [props removeObjectForKey:@"KBlocalizationKey"];
            }
            [props removeObjectForKey:@"KBshape"];
            [key setProperties:props];
            // Key views are cached by key name: it encodes the row's contents (and the
            // lettering, which differs between the two lowercase planes).
            [key setName:[NSString stringWithFormat:@"TPRKey-%lx-%ld-%lu-%lu%@", (unsigned long)rowTag, (long)kind,
                          (unsigned long)row, (unsigned long)i, capitalDisplay ? @"C" : @""]];
            [key setCache:[NSMutableDictionary dictionary]];
            [key setSubtrees:nil];   // no long-press list (an empty one crashes on touch)
        }
        [newKeys addObject:key];
        if (hasAttrs) {
            NSMutableDictionary *attrs = PositionAttributes(stockAttrs, i, count);
            id own = stock != NSNotFound ? stockAttrs[stock] : nil;
            if ([own isKindOfClass:[NSDictionary class]] && own[@"more-after"]) attrs[@"more-after"] = own[@"more-after"];
            [newAttrs addObject:attrs];
        }
    }
    for (id key in stockKeys)
        if (![used containsObject:key]) [removed addObject:key];

    NSString *(^units)(double) = ^(double value) { return [NSString stringWithFormat:@"%.6f", value]; };
    layoutProps[keysProp] = units(width);
    for (id pad in @[ children[at - 1], children[at + 1] ])
        rowProps[DynamicWidthProperty(pad, rowProps) ?: TPRProperties(pad)[@"KBrepresentedString"]] = units(padding);
    [(id<TPRKBTree>)layout setProperties:layoutProps];
    [(id<TPRKBTree>)rowLayout setProperties:rowProps];
    [(id<TPRKBTree>)keysetRow setSubtrees:newKeys];
    if (hasAttrs) [(id<TPRKBTree>)attrList setSubtrees:newAttrs];
    return nil;
}

static NSUInteger CustomizeDynamicPlane(id plane, BOOL lettersStock, TPRConfig *config, NSString **why) {
    TPRKeyPlane kind = KeyPlaneOf(plane);
    BOOL letters = kind == TPRKeyPlaneLetters || kind == TPRKeyPlaneShifted;
    if (letters ? !lettersStock : !IsStockDynamicPlane(plane, kind)) return 0;
    id layout, rowSet;
    if (!FindDynamicRowSet(plane, &layout, &rowSet)) return 0;
    // UIKit reads widths from the plane's first key layout.
    if (layout != TPRChildOfType(plane, TPRNodeKeylayout)) { *why = @"not the plane's first key layout"; return 0; }
    NSArray<NSNumber *> *rows = DynamicCharacterRows(rowSet);
    NSArray *attrRows = TPRSubtrees(TPRChildOfType(layout, TPRNodeAttributeSet));
    NSHashTable *removed = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSUInteger changed = 0;
    for (NSUInteger row = 0; row < TPRKeyRowCount && row < rows.count; row++) {
        NSArray *labels = [config keysForPlane:kind row:row];
        if (!labels) continue;
        NSUInteger index = rows[row].unsignedIntegerValue;
        id attrRow = attrRows.count == TPRSubtrees(rowSet).count ? attrRows[index] : nil;
        NSString *problem = CustomizeDynamicRow(layout, TPRSubtrees(rowSet)[index], attrRow, row, kind, labels, removed);
        if (problem) *why = [NSString stringWithFormat:@"row %lu: %@", (unsigned long)row + 1, problem];
        else changed++;
    }
    PruneKeyCache(plane, removed);
    return changed;
}

// Applies the Keys page to a copied plane. Returns how many rows changed; *why gets the
// reason a configured row couldn't be applied, if one couldn't.
static NSUInteger CustomizePlane(id plane, BOOL lettersStock, TPRConfig *config, NSString **why) {
    TPRKeyPlane kind = KeyPlaneOf(plane);
    BOOL letters = kind == TPRKeyPlaneLetters || kind == TPRKeyPlaneShifted;
    if (letters ? !lettersStock : !IsStockKeyPlane(plane, kind)) return 0;
    id keyset, geometrySet, attributeSet;
    if (!FindKeyLayout(plane, &keyset, &geometrySet, &attributeSet)) return 0;
    NSHashTable *removed = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSUInteger changed = 0;
    for (NSUInteger row = 0; row < TPRKeyRowCount; row++) {
        NSArray *labels = [config keysForPlane:kind row:row];
        if (!labels) continue;
        NSString *problem = CustomizeRow(plane, keyset, geometrySet, attributeSet, row, kind, labels, removed);
        if (problem) *why = [NSString stringWithFormat:@"row %lu: %@", (unsigned long)row + 1, problem];
        else changed++;
    }
    PruneKeyCache(plane, removed);
    return changed;
}

// Key Height: scale every shape's vertical geometry in a (copied) plane.
static NSString *ScalePlaneY(id plane, double scale) {
    NSHashTable *shapes = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSHashTable *unused = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    CollectShapes(plane, shapes, unused, 0);
    for (id shape in shapes) {
        CGRect f, p;
        if (!TPRGetFrames(shape, &f, &p)) return @"shape frame unreadable";
        f = CGRectMake(f.origin.x, f.origin.y * scale, f.size.width, f.size.height * scale);
        if (!CGRectEqualToRect(p, CGRectZero))
            p = CGRectMake(p.origin.x, p.origin.y * scale, p.size.width, p.size.height * scale);
        TPRSetFrames(shape, f, p);
    }
    return nil;
}

// Our own entries in UIKit's property dictionaries (UIKit ignores unknown keys).
static NSString *const kLandscapeKey = @"TPRlandscape";   // on a patched keyboard
static NSString *const kPatchedPlaneKey = @"TPRpatched";  // on each of its keyplanes
static NSString *const kExtraRowsKey = @"TPRextraRows";   // on a patched dynamic keyboard: rows added
static NSString *const kHeightFactorKey = @"TPRheightFactor";   // and how much taller it gets
static NSString *const kLandscapeHeightFactorKey = @"TPRlandscapeHeightFactor";   // the same, in landscape

// Height factors per layout of dynamic keyboard, @[portrait, landscape]: "QWERTY" for
// "Dynamic-QWERTY-Small", "QWERTZ-German" for "Dynamic-QWERTZ-German-Small". TextInputUI sizes
// a keyboard by its input mode's layout (that same string) and keeps a layout's keyboard
// across keyboard types and rotations, so the factor goes with the layout, not with whichever
// keyboard was handed back last.
static NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *DynamicHeightFactors(void) {
    static NSMutableDictionary *factors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ factors = [NSMutableDictionary dictionary]; });
    return factors;
}

static BOOL IsPadName(NSString *name) {
    for (NSString *pad in @[ @"NumberPad", @"PhonePad", @"DecimalPad", @"PasscodePad" ])
        if ([name containsString:pad] && ![name containsString:@"NamePhonePad"]) return YES;
    return NO;
}

// "Dynamic-QWERTZ-German-Small-Email" -> layout "QWERTZ-German", kind "Email"; the kind is ""
// for a layout's own keyboard. NO for names that aren't dynamic keyboards.
static BOOL ParseDynamicName(NSString *name, NSString **layout, NSString **kind) {
    NSArray<NSString *> *parts = [name componentsSeparatedByString:@"-"];
    if (parts.count < 3 || ![parts[0] isEqualToString:@"Dynamic"]) return NO;
    NSUInteger size = NSNotFound;   // the screen-size part TextInputUI appends
    for (NSUInteger i = 2; i < parts.count; i++)
        if ([@[ @"Mini", @"Small", @"Medium", @"Large", @"Grand" ] containsObject:parts[i]]) size = i;
    if (size == NSNotFound) return NO;
    if (layout) *layout = [[parts subarrayWithRange:NSMakeRange(1, size - 1)] componentsJoinedByString:@"-"];
    if (kind) *kind = [[parts subarrayWithRange:NSMakeRange(size + 1, parts.count - size - 1)] componentsJoinedByString:@"-"];
    return YES;
}

// The Keyboard Types switch for a keyboard named "...-Email" (URL, ...); YES for other names.
static BOOL RowOnKeyboardNamed(NSString *name, TPRConfig *config) {
    if ([name containsString:@"-Email"]) return config.rowOnEmail;
    if ([name containsString:@"-URL"] || [name containsString:@"AlphaWithURL"]) return config.rowOnWeb;
    if ([name containsString:@"-Twitter"]) return config.rowOnTwitter;
    return YES;
}

NSString *TPRDynamicSharedName(NSString *name, TPRConfig *config) {
    NSString *layout, *kind;
    if (gDynamicUnsupported || !ParseDynamicName(name, &layout, &kind) || !kind.length || IsPadName(name)) return nil;
    if (!config.enabled || RowOnKeyboardNamed(name, config)) return nil;
    NSString *app = NSBundle.mainBundle.bundleIdentifier;
    if (app && [config.excludedApps containsObject:app]) return nil;
    return [name substringToIndex:name.length - kind.length - 1];
}

double TPRDynamicHeightFactor(NSString *layout, NSInteger keyboardType, BOOL landscape, TPRConfig *config) {
    switch (keyboardType) {
        case 4: case 5: case 8: case 11: return 1;   // number, phone, decimal, ASCII number pads
        case 6: return 1;                             // name-phone pad: left as Apple's (see BuildPatchedKeyboard)
        case 7: if (!config.rowOnEmail) return 1; break;
        case 3: case 10: if (!config.rowOnWeb) return 1; break;   // URL, web search
        case 9: if (!config.rowOnTwitter) return 1; break;
        default: break;
    }
    if (![layout isKindOfClass:[NSString class]]) return 1;
    NSString *parsed;
    if (ParseDynamicName(layout, &parsed, NULL)) layout = parsed;   // in case a keyboard name comes instead
    @synchronized(DynamicHeightFactors()) {
        NSArray<NSNumber *> *factors = DynamicHeightFactors()[layout];
        return factors ? factors[landscape ? 1 : 0].doubleValue : 1;
    }
}

// Called with every keyboard handed back (patched or not). Only a layout's own keyboard
// counts: pads and types switched off are sized as Apple's by TPRDynamicHeightFactor.
static void RecordDynamicKeyboard(id keyboard, NSString *name, id patched, BOOL landscape) {
    NSString *layout, *kind;
    if (!ParseDynamicName(name, &layout, &kind) || kind.length || IsPadName(name) ||
        [name containsString:@"NamePhonePad"] || !TPRIsDynamicKeyboard(keyboard))
        return;
    NSDictionary *props = TPRProperties(patched);
    NSNumber *factor = [props[kHeightFactorKey] isKindOfClass:[NSNumber class]] ? props[kHeightFactorKey] : @1;
    NSNumber *landscapeFactor = [props[kLandscapeHeightFactorKey] isKindOfClass:[NSNumber class]]
        ? props[kLandscapeHeightFactorKey] : factor;
    @synchronized(DynamicHeightFactors()) {
        NSArray<NSNumber *> *old = DynamicHeightFactors()[layout];
        // A landscape-only keyboard (built when landscape differs) leaves the portrait factor be.
        DynamicHeightFactors()[layout] = landscape ? @[ old ? old[0] : @1, factor ] : @[ factor, landscapeFactor ];
    }
}

// Every keyplane of a patched keyboard is tagged as ours, and keysets/geometry sets that
// PatchPlane didn't rename (planes without a row) get the fingerprint too. Custom 123/ABC
// labels go only on tagged planes: on Apple's own trees they'd be drawn into artwork
// cached under Apple's names, which a later label change could never replace.
static void MarkPlane(id plane, NSString *fingerprint) {
    for (id layout in TPRSubtrees(plane)) {
        if (TPRType(layout) != TPRNodeKeylayout || [TPRName(layout) containsString:@"Control"]) continue;
        for (id node in @[ TPRChildOfType(layout, TPRNodeKeyset) ?: [NSNull null],
                           TPRChildOfType(layout, TPRNodeGeometrySet) ?: [NSNull null] ]) {
            NSString *name = TPRName(node);
            if (name && ![name containsString:@"-TPR"])
                [(id<TPRKBTree>)node setName:[NSString stringWithFormat:@"%@-TPR%@", name, fingerprint]];
        }
    }
    NSMutableDictionary *props = [TPRProperties(plane) mutableCopy] ?: [NSMutableDictionary dictionary];
    props[kPatchedPlaneKey] = @YES;
    [(id<TPRKBTree>)plane setProperties:props];
}

BOOL TPRIsPatchedKeyplane(id keyplane) {
    return [TPRProperties(keyplane)[kPatchedPlaneKey] isEqual:@YES];
}

static NSMapTable *PatchedCache(void) {
    static NSMapTable *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
                                      valueOptions:NSPointerFunctionsStrongMemory];
    });
    return cache;
}

// Landscape iPhone keyboards aren't reliably named "...Landscape..." (iPhone 15 Pro:
// portrait "iPhone-PortraitChoco-QWERTY", landscape "iPhone-Caymen-QWERTY"), so also
// look at the design frame: portrait ~375x216 (aspect ~1.7), landscape ~568x162 (~3.5).
BOOL TPRIsLandscapeKeyboard(id keyboard, NSString *name) {
    // A patched keyboard is taller than Apple's, so use what was decided when patching it.
    NSNumber *known = TPRProperties(keyboard)[kLandscapeKey];
    if ([known isKindOfClass:[NSNumber class]]) return known.boolValue;
    if ([name containsString:@"Landscape"]) return YES;
    CGRect frame;
    return TPRGetFrames(keyboard, &frame, NULL) && frame.size.height > 0 && frame.size.width / frame.size.height > 2.4;
}

static id BuildPatchedKeyboard(id keyboard, NSString *name, TPRConfig *config, BOOL dynamicLandscape, NSString **outcome) {
    if (!config.enabled) { *outcome = @"SKIP disabled"; return nil; }
    NSString *app = NSBundle.mainBundle.bundleIdentifier;
    if (app && [config.excludedApps containsObject:app]) { *outcome = @"SKIP excluded app"; return nil; }
    if (TPRType(keyboard) != TPRNodeKeyboard || !HasSetters(keyboard)) { *outcome = @"SKIP not a keyboard"; return nil; }
    // CarPlay keyboards ("Car-Landscape-QWERTY", "Car-Alphabetic-Linear-Keyboard") have a
    // fixed height on the car screen, so an added row lands on top of the letters.
    if ([name hasPrefix:@"Car-"]) { *outcome = @"SKIP CarPlay"; return nil; }
    // Only letter keyboards get a row. Number/phone/decimal/passcode pads have no
    // letters plane; their rows are 3 keys wide and must be left alone.
    for (NSString *pad in @[ @"NumberPad", @"PhonePad", @"DecimalPad", @"PasscodePad" ])
        if ([name containsString:pad] && ![name containsString:@"NamePhonePad"]) { *outcome = @"SKIP numeric pad"; return nil; }
    BOOL hasLetters = NO;
    for (id plane in TPRSubtrees(keyboard))
        if (TPRType(plane) == TPRNodeKeyplane && [plane respondsToSelector:@selector(isAlphabeticPlane)] &&
            [(id<TPRKBTree>)plane isAlphabeticPlane])
            hasLetters = YES;
    if (!hasLetters) { *outcome = @"SKIP no letters plane"; return nil; }
    if (!RowOnKeyboardNamed(name, config)) {
        *outcome = @"SKIP keyboard type turned off";
        return nil;
    }
    BOOL dynamic = TPRIsDynamicKeyboard(keyboard);
    if (dynamic && gDynamicUnsupported) { *outcome = [@"SKIP " stringByAppendingString:gDynamicUnsupported]; return nil; }
    // iOS 26 sizes a keyboard once for all its planes, so the name-phone pad's phone plane
    // would be stretched along with its letters: that keyboard stays Apple's.
    if (dynamic && [name containsString:@"NamePhonePad"]) { *outcome = @"SKIP name-phone pad"; return nil; }
    // One dynamic tree serves both orientations: the caller says which one this copy is for.
    BOOL landscape = dynamic ? dynamicLandscape : TPRIsLandscapeKeyboard(keyboard, name);
    // "Show in Landscape" is about the extra row and the height it adds: turned off, a
    // landscape keyboard keeps its size but still gets custom keys (and their labels).
    BOOL rowOff = landscape && !config.showInLandscape;
    if (rowOff && !config.hasCustomKeys) { *outcome = @"SKIP landscape"; return nil; }
    CGFloat heightScale = rowOff ? 1 : config.keyHeightScale;

    // Custom letter rows only on a keyboard whose letter planes are all Apple's US rows
    // (Turkish Q, for one, matches in lowercase but not with Shift).
    BOOL lettersStock = config.hasCustomKeys;
    for (id plane in TPRSubtrees(keyboard))
        if (lettersStock && TPRType(plane) == TPRNodeKeyplane && PlaneKind(plane) != TPRPlaneNumbers)
            lettersStock = dynamic ? IsStockDynamicPlane(plane, KeyPlaneOf(plane)) : IsStockKeyPlane(plane, KeyPlaneOf(plane));

    NSUInteger extraRows = 0;
    NSMutableArray *planes = [NSMutableArray array], *rowless = [NSMutableArray array];
    CGFloat pitch = 0;
    NSUInteger patchedCount = 0, customRows = 0;
    NSString *keysProblem = nil, *rowProblem = nil;
    for (id plane in TPRSubtrees(keyboard)) {
        // `keyboard` is our pristine copy: everything handed to UIKit must be a fresh
        // copy (UIKit lays trees out in place), even planes that get no extra row.
        NSMapTable *copies = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality
                                                   valueOptions:NSPointerFunctionsStrongMemory];
        NSUInteger budget = kCopyBudget;
        id copy = DeepCopy(plane, copies, &budget, 0);
        if (!copy) { *outcome = [NSString stringWithFormat:@"SKIP copy failed: %@", TPRName(plane)]; return nil; }
        BOOL keyplane = TPRType(plane) == TPRNodeKeyplane;
        NSArray *labels = keyplane && !rowOff ? [config rowForPlane:PlaneKind(plane) landscape:landscape] : nil;
        BOOL changed = NO, gotRow = NO;
        if (labels.count && dynamic) {
            NSArray *hints = config.symbolHints && PlaneKind(plane) == TPRPlaneLowercase
                ? [config rowForPlane:TPRPlaneShifted landscape:landscape] : nil;
            NSString *why = PatchDynamicPlane(copy, labels, hints, InsertRowForPlane(PlaneKind(plane)), config.fingerprint);
            if (why && PlaneKind(plane) != TPRPlaneNumbers) {
                *outcome = [NSString stringWithFormat:@"SKIP %@: %@", TPRName(plane), why];
                return nil;
            }
            if (why) {   // start that plane over from a fresh copy
                rowProblem = [NSString stringWithFormat:@"%@: %@", TPRName(plane), why];
                NSUInteger freshBudget = kCopyBudget;
                copy = DeepCopy(plane, [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality
                                                             valueOptions:NSPointerFunctionsStrongMemory], &freshBudget, 0);
                if (!copy) { *outcome = [NSString stringWithFormat:@"SKIP copy failed: %@", TPRName(plane)]; return nil; }
            } else {
                changed = gotRow = YES;
                extraRows = 1;
            }
        } else if (labels.count) {
            CGFloat planePitch = 0;
            NSArray *hints = config.symbolHints && PlaneKind(plane) == TPRPlaneLowercase
                ? [config rowForPlane:TPRPlaneShifted landscape:landscape] : nil;
            NSString *why = PatchPlane(copy, labels, hints, InsertRowForPlane(PlaneKind(plane)), config.fingerprint, &planePitch);
            // A letters plane that can't take the row means an unfamiliar layout: leave the keyboard
            // alone. A non-letters plane without a full-width row (e.g. a phone pad) just gets none.
            if (why && PlaneKind(plane) != TPRPlaneNumbers) {
                *outcome = [NSString stringWithFormat:@"SKIP %@: %@", TPRName(plane), why];
                return nil;
            }
            if (why) {   // PatchPlane may have partly edited the copy: start that plane over
                NSUInteger freshBudget = kCopyBudget;
                copy = DeepCopy(plane, [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality
                                                             valueOptions:NSPointerFunctionsStrongMemory], &freshBudget, 0);
                if (!copy) { *outcome = [NSString stringWithFormat:@"SKIP copy failed: %@", TPRName(plane)]; return nil; }
            } else {
                if (pitch && fabs(pitch - planePitch) > 0.5) { *outcome = @"SKIP planes disagree on row pitch"; return nil; }
                pitch = planePitch;
                changed = YES;
            }
        }
        // Custom keys after the extra row (which they leave in place), before Key Height.
        if (keyplane && config.hasCustomKeys) {
            NSUInteger rows = dynamic ? CustomizeDynamicPlane(copy, lettersStock, config, &keysProblem)
                                      : CustomizePlane(copy, lettersStock, config, &keysProblem);
            customRows += rows;
            if (rows) changed = YES;
        }
        // Key Height scales the plane after the row is in, so the row scales with it.
        if (keyplane && fabs(heightScale - 1) > 0.001) {
            NSString *why = ScalePlaneY(copy, heightScale);
            if (why) { *outcome = [NSString stringWithFormat:@"SKIP %@: %@", TPRName(plane), why]; return nil; }
            changed = YES;
        }
        if (changed) patchedCount++;
        if (keyplane && dynamic && !gotRow) [rowless addObject:copy];
        [planes addObject:copy];
    }
    if (!patchedCount) { *outcome = @"SKIP no rows configured"; return nil; }
    if (dynamic && extraRows)
        for (id plane in rowless) {
            NSString *why = InsertDynamicSpacer(plane, config.fingerprint);
            if (why) { *outcome = [NSString stringWithFormat:@"SKIP %@: spacer: %@", TPRName(plane), why]; return nil; }
        }
    for (id plane in planes)
        if (TPRType(plane) == TPRNodeKeyplane) MarkPlane(plane, config.fingerprint);

    id<TPRKBTree> patched = [keyboard copy];
    if (!patched || patched == keyboard) { *outcome = @"SKIP keyboard copy failed"; return nil; }
    NSMutableDictionary *props = [TPRProperties(keyboard) mutableCopy] ?: [NSMutableDictionary dictionary];
    id shape = [TPRShapeOf(keyboard) copy];
    CGRect f, p;
    if (shape && TPRGetFrames(shape, &f, &p)) {
        f.size.height = (f.size.height + pitch) * heightScale;
        TPRSetFrames(shape, f, p);
        props[@"KBshape"] = shape;
    }
    props[kLandscapeKey] = @(landscape);
    if (dynamic) {
        // TextInputUI splits the keyboard's height between its rows: grow it by the added row
        // (Apple's dynamic letter planes have 4 rows) and apply Key Height on top.
        NSUInteger baseRows = 0;
        id layout, rowSet;
        for (id plane in TPRSubtrees(keyboard))
            if (!baseRows && TPRType(plane) == TPRNodeKeyplane && FindDynamicRowSet(plane, &layout, &rowSet))
                baseRows = TPRSubtrees(rowSet).count;
        double factor = (baseRows ? (double)(baseRows + extraRows) / baseRows : 1) * heightScale;
        props[kExtraRowsKey] = @(extraRows);
        props[kHeightFactorKey] = @(factor);
        // A tree built for portrait also serves landscape unless landscape differs, and then
        // its own landscape copy only keeps the height with the row shown.
        props[kLandscapeHeightFactorKey] = @(landscape || config.showInLandscape ? factor : 1);
    }
    if (TPRName(keyboard)) [patched setName:TPRName(keyboard)];
    [patched setProperties:props];
    [patched setSubtrees:planes];
    [patched setCache:[NSMutableDictionary dictionary]];
    *outcome = [NSString stringWithFormat:@"PATCHED %lu/%lu planes, %@%@, %lu custom key rows%@%@",
                (unsigned long)patchedCount, (unsigned long)planes.count,
                dynamic ? [NSString stringWithFormat:@"dynamic +%lu row", (unsigned long)extraRows]
                        : [NSString stringWithFormat:@"+%.0f design pt", pitch], landscape ? @" (landscape)" : @"",
                (unsigned long)customRows, keysProblem ? [@"; keys " stringByAppendingString:keysProblem] : @"",
                rowProblem ? [@"; no row on " stringByAppendingString:rowProblem] : @""];
    return patched;
}

// Untouched deep copy of each original keyboard, taken the first time we see it.
// Whenever we don't patch (disabled, excluded, landscape off) UIKit gets the
// original and lays it out in place, so later patches must start from this copy.
static NSMapTable *PristineCache(void) {
    static NSMapTable *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
                                      valueOptions:NSPointerFunctionsStrongMemory];
    });
    return cache;
}

static id PristineCopy(id keyboard) {
    id pristine = [PristineCache() objectForKey:keyboard];
    if (!pristine) {
        NSMapTable *copies = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality
                                                   valueOptions:NSPointerFunctionsStrongMemory];
        NSUInteger budget = kCopyBudget * 8;
        pristine = DeepCopy(keyboard, copies, &budget, 0);
        if (pristine) [PristineCache() setObject:pristine forKey:keyboard];
    }
    return pristine;
}

id TPRPatchKeyboard(id keyboard, NSString *name, TPRConfig *config, BOOL landscape, NSString **outcome) {
    // The serializer hands back one cached keyboard object per name; mirror that
    // by handing back one patched copy per original, so UIKit sees a stable object.
    // iOS 26 serves several names (keyboard types) and both orientations from one
    // original, so each name and orientation gets its own copy.
    landscape = landscape && TPRIsDynamicKeyboard(keyboard);
    NSString *variant = [NSString stringWithFormat:@"%@%@", name, landscape ? @"|landscape" : @""];
    @synchronized(PatchedCache()) {
        NSMutableDictionary *entries = [PatchedCache() objectForKey:keyboard];
        NSArray *entry = entries[variant];
        if ([entry.firstObject isEqual:config.fingerprint]) {
            *outcome = @"cached";
            id cached = entry.lastObject == [NSNull null] ? nil : entry.lastObject;
            RecordDynamicKeyboard(keyboard, name, cached, landscape);
            return cached;
        }
        id patched = nil;
        gCopyingDynamic = TPRIsDynamicKeyboard(keyboard);
        @try {
            // Copied at first sight even when not patching: UIKit lays the original out in place.
            id pristine = TPRIsTree(keyboard) ? PristineCopy(keyboard) : nil;
            patched = pristine ? BuildPatchedKeyboard(pristine, name, config, landscape, outcome) : nil;
            if (!pristine) *outcome = @"SKIP pristine copy failed";
        } @catch (NSException *e) {
            *outcome = [NSString stringWithFormat:@"SKIP exception %@", e.reason];
            patched = nil;
        }
        // Copies made for an older config are dropped with it.
        NSMutableDictionary *current = [NSMutableDictionary dictionary];
        for (NSString *key in entries)
            if ([[entries[key] firstObject] isEqual:config.fingerprint]) current[key] = entries[key];
        current[variant] = @[ config.fingerprint, patched ?: [NSNull null] ];
        [PatchedCache() setObject:current forKey:keyboard];
        RecordDynamicKeyboard(keyboard, name, patched, landscape);
        return patched;
    }
}

static void CollectRowKeys(id node, NSMutableArray *keys, id *keyset, int depth) {
    if (depth > kMaxDepth) return;
    for (id child in TPRSubtrees(node)) {
        if (TPRType(child) == TPRNodeKey && [TPRName(child) hasPrefix:@"TopRow-"]) {
            [keys addObject:child];
            if (keyset && !*keyset) *keyset = node;   // the row list; its parent is found below
        }
        CollectRowKeys(child, keys, keyset, depth + 1);
    }
}

static id FindKeysetContaining(id node, id row, int depth) {
    if (depth > kMaxDepth) return nil;
    for (id child in TPRSubtrees(node)) {
        if (child == row) return node;
        id found = FindKeysetContaining(child, row, depth + 1);
        if (found) return found;
    }
    return nil;
}

BOOL TPRRelabelShiftedRow(id keyplane, BOOL autoShifted, BOOL landscape, TPRConfig *config) {
    if (!config.lowercaseRowWhenAutoShifted || PlaneKind(keyplane) != TPRPlaneShifted) return NO;
    NSArray *labels = [config rowForPlane:autoShifted ? TPRPlaneLowercase : TPRPlaneShifted landscape:landscape];
    // The lowercase row keeps its symbol hints when shown here too.
    NSArray *hints = autoShifted && config.symbolHints ? [config rowForPlane:TPRPlaneShifted landscape:landscape] : nil;
    NSMutableArray *keys = [NSMutableArray array];
    id row = nil;
    CollectRowKeys(keyplane, keys, &row, 0);
    if (!keys.count || keys.count != labels.count) return NO;
    BOOL same = YES;
    for (NSUInteger i = 0; i < keys.count && same; i++)
        same = [TPRProperties(keys[i])[@"KBdisplayString"] isEqual:labels[i]];
    if (same) return NO;
    NSUInteger rowTag = [labels componentsJoinedByString:@"\x1f"].hash;
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSMutableDictionary *props = [TPRProperties(keys[i]) mutableCopy];
        props[@"KBdisplayString"] = labels[i];
        props[@"KBrepresentedString"] = labels[i];
        if (hints.count == keys.count) props[@"TPRhint"] = hints[i];
        else [props removeObjectForKey:@"TPRhint"];
        [(id<TPRKBTree>)keys[i] setProperties:props];
        [(id<TPRKBTree>)keys[i] setName:[NSString stringWithFormat:@"TopRow-%lx-Key-%lu", (unsigned long)rowTag, (unsigned long)i]];
        [(id<TPRKBTree>)keys[i] setCache:[NSMutableDictionary dictionary]];
    }
    // Rendered keyplane images are keyed partly by the keyset's name: give each
    // variant its own so the two versions are cached separately. (Dynamic keyboards cache key
    // views by the keys' names, changed above; their row's keyset must keep its name, which
    // its key width is looked up by.)
    id keyset = FindKeysetContaining(keyplane, row, 0);
    NSString *name = TPRType(keyset) == TPRNodeKeyset ? TPRName(keyset) : nil;
    NSRange mark = [name rangeOfString:@"-TPRv"];
    if (name && mark.location != NSNotFound) name = [name substringToIndex:mark.location];
    if (name) [(id<TPRKBTree>)keyset setName:[NSString stringWithFormat:@"%@-TPRv%@", name, autoShifted ? @"a" : @"m"]];
    return YES;
}
