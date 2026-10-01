/// Deterministic class sorting.
///
/// Replaces the task-03 stub. Implements `sortClasses(allocator, input, theme_css)`
/// which the test runner calls per fixture.
///
/// Algorithm (Phase 1, faithful enough for the 10 sort fixtures):
///   1. Parse each class via candidate.zig.
///   2. Compute a sort key per class:
///      - Unknown or unparseable classes → null (sort to front,
///        preserve input order).
///      - Known classes → a multi-field key combining: !important flag,
///        variant count, property bucket index, alphabetical position.
///   3. Stable-sort by key.
///   4. Join with spaces.
///
/// The legacy `theme_css` argument remains accepted by `sortClasses`; compilation
/// calls `sortClassesWithTheme` with its resolved tokens so custom breakpoints and
/// overrides participate in cascade ordering.
const std = @import("std");
const candidate = @import("candidate.zig");
const utilities = @import("utilities.zig");
const theme = @import("theme.zig");

pub const SortError = error{
    NotImplemented,
    OutOfMemory,
};

pub fn sortClasses(
    allocator: std.mem.Allocator,
    input: []const u8,
    theme_css: []const u8,
) SortError![]u8 {
    _ = theme_css; // Legacy sorting API; compilation uses the resolved token theme below.
    return sortClassesWithTheme(allocator, input, .{ .tokens = &.{} });
}

pub fn sortClassesWithTheme(
    allocator: std.mem.Allocator,
    input: []const u8,
    t: theme.Theme,
) SortError![]u8 {

    // Split input on whitespace.
    var classes = std.array_list.Managed([]const u8).init(allocator);
    defer classes.deinit();
    var it = std.mem.tokenizeAny(u8, input, " \t\n\r");
    while (it.next()) |c| try classes.append(c);

    if (classes.items.len == 0) {
        return allocator.dupe(u8, "") catch return SortError.OutOfMemory;
    }

    // Compute sort entries: (class_name, sort_key, input_index).
    // input_index breaks ties to keep stability.
    const Entry = struct {
        name: []const u8,
        key: ?u64,
        idx: u32,
    };

    const entries = try allocator.alloc(Entry, classes.items.len);
    defer allocator.free(entries);

    for (classes.items, 0..) |name, i| {
        entries[i] = .{
            .name = name,
            .key = sortKey(allocator, name, t) catch |err| switch (err) {
                error.OutOfMemory => return SortError.OutOfMemory,
            },
            .idx = @intCast(i),
        };
    }

    std.mem.sort(Entry, entries, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            // Both null: preserve input order.
            if (a.key == null and b.key == null) return a.idx < b.idx;
            // Null sorts to front.
            if (a.key == null) return true;
            if (b.key == null) return false;
            if (a.key.? != b.key.?) return a.key.? < b.key.?;
            // Same key (same bucket + same variant chain + same important):
            // tiebreak on the full class name lexicographically. This gives
            // `bg-blue-500 < bg-red-500` etc.
            const cmp = std.mem.order(u8, a.name, b.name);
            if (cmp == .lt) return true;
            if (cmp == .gt) return false;
            return a.idx < b.idx;
        }
    }.lessThan);

    // Join.
    var total: usize = 0;
    for (entries) |e| total += e.name.len;
    if (entries.len > 1) total += entries.len - 1;
    var out = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (entries, 0..) |e, i| {
        if (i > 0) {
            out[pos] = ' ';
            pos += 1;
        }
        @memcpy(out[pos .. pos + e.name.len], e.name);
        pos += e.name.len;
    }
    return out;
}

/// Compute a sort key for a class name. Returns null for unknown or unparseable
/// classes (they sort to the front in input order).
///
/// Key layout (high to low bits):
///   - bit 60:    !important (1 = important, sorts later within its group)
///   - bits 52-59: variant count (more variants → later)
///   - bits 36-51: breakpoint priority (16 bits) — min-width in rem × 16,
///                 so larger breakpoints sort LATER and override smaller
///                 ones in the cascade. Zero when no breakpoint variant.
///   - bits 16-35: property bucket index (lower = earlier in cascade)
///   - bits 0-15: alphabetical position (per class-name slot in bucket)
///
/// **Why breakpoint priority matters**: at a wide viewport, both `sm:X` and
/// `lg:X` media queries match. The CSS cascade gives the win to whichever
/// rule comes LATER in source order. So we need `sm:X` emitted BEFORE
/// `lg:X` to make `lg:X` win.
fn sortKey(allocator: std.mem.Allocator, name: []const u8, t: theme.Theme) error{OutOfMemory}!?u64 {
    const cands = try candidate.parseCandidate(allocator, name);
    defer candidate.freeCandidates(allocator, cands);

    // Parser failed: not a recognized class.
    if (cands.len == 0) return null;

    // Pick the candidate whose root we can place in the bucket table. Prefer
    // arbitrary > functional with a known bucket > static.
    var best_bucket: ?u32 = null;
    var best_cand: ?candidate.Candidate = null;
    for (cands) |c| {
        const root = candidateRoot(c);
        if (bucketForRoot(root)) |b| {
            if (best_bucket == null or b < best_bucket.?) {
                best_bucket = b;
                best_cand = c;
            }
        }
    }

    // Fall back: if no candidate has a known bucket, use the first one with a
    // catchall bucket (e.g. arbitrary properties get a high bucket so they
    // sort consistently among themselves). A COMPILABLE utility outside the
    // bucket table gets the late catchall too — never a null key: null sorts
    // to the FRONT, which put `md:X` media rules before the base utilities
    // they must override (`hidden md:table-cell` stayed display:none at every
    // width until `table-cell` was bucketed). Author-custom classes (which
    // compile to nothing) keep the null key and the front-by-convention slot.
    if (best_bucket == null) {
        if (cands[0] == .arbitrary) {
            best_bucket = ARBITRARY_PROPERTY_BUCKET;
            best_cand = cands[0];
        } else {
            for (cands) |c| {
                if (c == .static_c and utilities.isStaticUtility(c.static_c.root)) {
                    best_bucket = UNKNOWN_UTILITY_BUCKET;
                    best_cand = c;
                    break;
                }
            }
            if (best_bucket == null) return null;
        }
    }

    const c = best_cand.?;
    const variants = switch (c) {
        .static_c => |s| s.variants,
        .functional => |f| f.variants,
        .arbitrary => |a| a.variants,
    };
    const important = switch (c) {
        .static_c => |s| s.important,
        .functional => |f| f.important,
        .arbitrary => |a| a.important,
    };

    // The most specific responsive condition determines cascade priority.
    // Larger minima and smaller maxima sort later.
    var bp_priority: u16 = 0;
    for (variants) |v| {
        const p = breakpointPriority(v, t);
        if (p > bp_priority) bp_priority = p;
    }

    var key: u64 = 0;
    if (important) key |= @as(u64, 1) << 60;
    key |= @as(u64, @min(variants.len, 0xFF)) << 52;
    key |= @as(u64, bp_priority) << 36;
    key |= @as(u64, best_bucket.? & 0xFFFFF) << 16;
    key |= @as(u64, alphaScore(name) & 0xFFFF);

    return key;
}

/// Min-width queries grow more specific as their threshold increases; max-width
/// queries grow more specific as it decreases. Resolve custom names and overrides
/// from the same theme used to emit the media queries.
fn breakpointPriority(v: candidate.Variant, t: theme.Theme) u16 {
    return switch (v) {
        .static_v => |s| breakpointForTheme(s.root, t),
        .functional => |f| blk: {
            const value = f.value orelse break :blk 0;
            if (value != .named) break :blk 0;
            var name_buffer: [512]u8 = undefined;
            const full_name = std.fmt.bufPrint(&name_buffer, "{s}-{s}", .{ f.root, value.named }) catch break :blk 0;
            const is_max = std.mem.startsWith(u8, full_name, "max-");
            const name = if (is_max) full_name[4..] else full_name;
            const p = breakpointForTheme(name, t);
            if (p == 0) break :blk 0;
            break :blk if (is_max) std.math.maxInt(u16) - p else p;
        },
        else => 0,
    };
}

fn breakpointForTheme(name: []const u8, t: theme.Theme) u16 {
    for (t.tokens) |token| {
        if (!std.mem.startsWith(u8, token.name, "breakpoint-")) continue;
        if (!std.mem.eql(u8, token.name["breakpoint-".len..], name)) continue;
        const value = std.mem.trim(u8, token.value, " ");
        const unit_len: usize = if (std.mem.endsWith(u8, value, "rem")) 3 else 2;
        const pixels = std.mem.endsWith(u8, value, "px");
        if (!pixels and !std.mem.endsWith(u8, value, "em")) return 0;
        if (value.len <= unit_len) return 0;
        const number = std.fmt.parseFloat(f64, value[0 .. value.len - unit_len]) catch return 0;
        const width = number * (if (pixels) @as(f64, 1) else 16);
        if (!std.math.isFinite(width) or width <= 0) return 0;
        return @intFromFloat(@min(width, 32767));
    }
    return breakpointFor(name);
}

fn breakpointFor(name: []const u8) u16 {
    if (std.mem.eql(u8, name, "sm")) return 640;
    if (std.mem.eql(u8, name, "md")) return 768;
    if (std.mem.eql(u8, name, "lg")) return 1024;
    if (std.mem.eql(u8, name, "xl")) return 1280;
    if (std.mem.eql(u8, name, "2xl")) return 1536;
    if (std.mem.eql(u8, name, "3xl")) return 1792;
    if (std.mem.eql(u8, name, "4xl")) return 2048;
    if (std.mem.eql(u8, name, "5xl")) return 2304;
    if (std.mem.eql(u8, name, "6xl")) return 2560;
    if (std.mem.eql(u8, name, "7xl")) return 2816;
    return 0;
}

fn candidateRoot(c: candidate.Candidate) []const u8 {
    return switch (c) {
        .static_c => |s| s.root,
        .functional => |f| f.root,
        .arbitrary => |a| a.property,
    };
}

/// Map a utility root to its property bucket index. Lower = earlier in cascade.
/// The bucket numbers implement the JIT's cascade order for known properties.
/// Extend them as class coverage grows.
const PropertyBucket = struct { root: []const u8, bucket: u32 };

const ARBITRARY_PROPERTY_BUCKET: u32 = 5000;

/// Parseable utility with no bucket entry: sorts after every curated bucket
/// (so it can override component-owned defaults) but before arbitrary
/// properties, and its variant/breakpoint bits still order `md:X` after `X`.
const UNKNOWN_UTILITY_BUCKET: u32 = 4000;

const PROPERTY_BUCKETS = [_]PropertyBucket{
    // ── Layout / position (very early in cascade) ──
    .{ .root = "static", .bucket = 10 },
    .{ .root = "relative", .bucket = 10 },
    .{ .root = "absolute", .bucket = 10 },
    .{ .root = "fixed", .bucket = 10 },
    .{ .root = "sticky", .bucket = 10 },
    .{ .root = "isolate", .bucket = 11 },
    .{ .root = "z", .bucket = 12 },
    .{ .root = "inset", .bucket = 13 },
    .{ .root = "top", .bucket = 14 },
    .{ .root = "right", .bucket = 14 },
    .{ .root = "bottom", .bucket = 14 },
    .{ .root = "left", .bucket = 14 },

    // ── Display / box ──
    .{ .root = "block", .bucket = 20 },
    .{ .root = "inline", .bucket = 20 },
    .{ .root = "inline-block", .bucket = 20 },
    .{ .root = "flex", .bucket = 20 },
    .{ .root = "inline-flex", .bucket = 20 },
    .{ .root = "grid", .bucket = 20 },
    .{ .root = "inline-grid", .bucket = 20 },
    .{ .root = "hidden", .bucket = 20 },
    .{ .root = "table", .bucket = 20 },
    .{ .root = "inline-table", .bucket = 20 },
    .{ .root = "table-caption", .bucket = 20 },
    .{ .root = "table-cell", .bucket = 20 },
    .{ .root = "table-column", .bucket = 20 },
    .{ .root = "table-column-group", .bucket = 20 },
    .{ .root = "table-footer-group", .bucket = 20 },
    .{ .root = "table-header-group", .bucket = 20 },
    .{ .root = "table-row", .bucket = 20 },
    .{ .root = "table-row-group", .bucket = 20 },
    .{ .root = "contents", .bucket = 20 },
    .{ .root = "flow-root", .bucket = 20 },
    .{ .root = "list-item", .bucket = 20 },
    .{ .root = "table-auto", .bucket = 24 },
    .{ .root = "table-fixed", .bucket = 24 },
    .{ .root = "caption-top", .bucket = 25 },
    .{ .root = "caption-bottom", .bucket = 25 },
    .{ .root = "border-collapse", .bucket = 26 },
    .{ .root = "border-separate", .bucket = 26 },
    .{ .root = "overflow", .bucket = 22 },
    .{ .root = "overflow-hidden", .bucket = 22 },
    .{ .root = "overflow-auto", .bucket = 22 },
    .{ .root = "overflow-visible", .bucket = 22 },

    // ── Sizing ──
    .{ .root = "size", .bucket = 30 },
    .{ .root = "w", .bucket = 31 },
    .{ .root = "h", .bucket = 32 },
    .{ .root = "max-w", .bucket = 33 },
    .{ .root = "max-h", .bucket = 34 },
    .{ .root = "min-w", .bucket = 35 },
    .{ .root = "min-h", .bucket = 36 },

    // ── Grid ──
    .{ .root = "grid-cols", .bucket = 40 },
    .{ .root = "col-span", .bucket = 41 },
    .{ .root = "grid-rows", .bucket = 42 },
    .{ .root = "row-span", .bucket = 43 },
    .{ .root = "gap", .bucket = 44 },
    .{ .root = "gap-x", .bucket = 45 },
    .{ .root = "gap-y", .bucket = 46 },

    // ── Flex ──
    .{ .root = "flex-row", .bucket = 50 },
    .{ .root = "flex-col", .bucket = 50 },
    .{ .root = "flex-wrap", .bucket = 51 },
    .{ .root = "items-center", .bucket = 52 },
    .{ .root = "items-start", .bucket = 52 },
    .{ .root = "items-end", .bucket = 52 },
    .{ .root = "justify-center", .bucket = 53 },
    .{ .root = "justify-start", .bucket = 53 },
    .{ .root = "justify-between", .bucket = 53 },
    .{ .root = "justify-end", .bucket = 53 },
    .{ .root = "self-center", .bucket = 54 },

    // ── Padding (cascade-affecting; shorthand-then-axis-then-side) ──
    .{ .root = "p", .bucket = 100 },
    .{ .root = "px", .bucket = 101 },
    .{ .root = "py", .bucket = 102 },
    .{ .root = "pt", .bucket = 103 },
    .{ .root = "pr", .bucket = 104 },
    .{ .root = "pb", .bucket = 105 },
    .{ .root = "pl", .bucket = 106 },

    // ── Margin ──
    .{ .root = "m", .bucket = 110 },
    .{ .root = "mx", .bucket = 111 },
    .{ .root = "my", .bucket = 112 },
    .{ .root = "mt", .bucket = 113 },
    .{ .root = "mr", .bucket = 114 },
    .{ .root = "mb", .bucket = 115 },
    .{ .root = "ml", .bucket = 116 },

    // ── Background (before padding/border) ──
    .{ .root = "bg", .bucket = 80 },
    .{ .root = "bg-linear-to", .bucket = 81 },
    .{ .root = "from", .bucket = 82 },
    .{ .root = "via", .bucket = 83 },
    .{ .root = "to", .bucket = 84 },

    // ── Border ──
    .{ .root = "border", .bucket = 200 },
    .{ .root = "border-x", .bucket = 201 },
    .{ .root = "border-y", .bucket = 202 },
    .{ .root = "border-t", .bucket = 203 },
    .{ .root = "border-r", .bucket = 204 },
    .{ .root = "border-b", .bucket = 205 },
    .{ .root = "border-l", .bucket = 206 },
    .{ .root = "rounded", .bucket = 220 },
    .{ .root = "ring", .bucket = 230 },
    .{ .root = "ring-inset", .bucket = 231 },

    // ── Typography ──
    .{ .root = "text", .bucket = 300 },
    .{ .root = "text-balance", .bucket = 301 },
    .{ .root = "text-pretty", .bucket = 301 },
    .{ .root = "text-wrap", .bucket = 301 },
    .{ .root = "text-nowrap", .bucket = 301 },
    .{ .root = "text-left", .bucket = 302 },
    .{ .root = "text-center", .bucket = 302 },
    .{ .root = "text-right", .bucket = 302 },
    .{ .root = "font", .bucket = 310 },
    .{ .root = "tracking", .bucket = 320 },
    .{ .root = "leading", .bucket = 330 },
    .{ .root = "antialiased", .bucket = 340 },
    .{ .root = "subpixel-antialiased", .bucket = 340 },

    // ── Effects ──
    .{ .root = "opacity", .bucket = 400 },
    .{ .root = "shadow", .bucket = 410 },

    // ── Transition ──
    .{ .root = "transition", .bucket = 500 },
    .{ .root = "transition-colors", .bucket = 500 },
    .{ .root = "transition-opacity", .bucket = 500 },
    .{ .root = "duration", .bucket = 510 },
};

fn bucketForRoot(root: []const u8) ?u32 {
    inline for (PROPERTY_BUCKETS) |entry| {
        if (std.mem.eql(u8, root, entry.root)) return entry.bucket;
    }
    // Negative-prefix fallback: `-z` → look up `z`.
    if (root.len > 1 and root[0] == '-') {
        inline for (PROPERTY_BUCKETS) |entry| {
            if (std.mem.eql(u8, root[1..], entry.root)) return entry.bucket;
        }
    }
    return null;
}

/// Compute a small alphabetical score for tie-breaking within a bucket.
/// Uses the first ~3 chars of the class name. 12 bits = 4096 slots.
fn alphaScore(s: []const u8) u32 {
    var score: u32 = 0;
    var i: usize = 0;
    while (i < s.len and i < 3) : (i += 1) {
        score = score * 256 + s[i];
    }
    return score & 0xFFF;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const tst = std.testing;

test "sortClasses: padding shorthand, x, y" {
    const out = try sortClasses(tst.allocator, "py-3 p-1 px-3", "");
    defer tst.allocator.free(out);
    try tst.expectEqualStrings("p-1 px-3 py-3", out);
}

test "sortClasses: variant count ordering" {
    const out = try sortClasses(tst.allocator, "px-3 focus:hover:p-3 hover:p-1 py-3", "");
    defer tst.allocator.free(out);
    try tst.expectEqualStrings("px-3 py-3 hover:p-1 focus:hover:p-3", out);
}

test "sortClasses: important sorts to end of group" {
    const out = try sortClasses(tst.allocator, "px-3 py-4! p-1", "");
    defer tst.allocator.free(out);
    try tst.expectEqualStrings("p-1 px-3 py-4!", out);
}

test "sortClasses: unknown classes preserve input order, sort to front" {
    const out = try sortClasses(tst.allocator, "b p-1 a", "");
    defer tst.allocator.free(out);
    try tst.expectEqualStrings("b a p-1", out);
}

test "sortClasses: bg sorts before p, alphabetical within bg" {
    const out = try sortClasses(
        tst.allocator,
        "a-class px-3 p-1 b-class py-3 bg-red-500 bg-blue-500",
        "",
    );
    defer tst.allocator.free(out);
    try tst.expectEqualStrings("a-class b-class bg-blue-500 bg-red-500 p-1 px-3 py-3", out);
}

test "sortClasses: arbitrary properties preserve input order" {
    const out = try sortClasses(
        tst.allocator,
        "[--bg:#111] [--bg_hover:#000] [--fg:#fff]",
        "",
    );
    defer tst.allocator.free(out);
    try tst.expectEqualStrings("[--bg:#111] [--bg_hover:#000] [--fg:#fff]", out);
}

test "sortClasses: responsive display override sorts after base display" {
    // The regression that hid the dashboard's author column: `md:table-cell`
    // must come after `hidden` in the emitted CSS or display:none wins at
    // every viewport width. table-* utilities are compilable statics, so they
    // sort by bucket (or the late catchall) — never to the front.
    const out = try sortClasses(tst.allocator, "md:table-cell w-[180px] hidden", "");
    defer tst.allocator.free(out);
    try tst.expectEqualStrings("hidden w-[180px] md:table-cell", out);
}

test "sortClasses: compilable static utility without a bucket sorts late, not front" {
    // `sr-only` resolves as a static utility but has no property-bucket
    // entry: it lands in the late catchall, while a truly custom class keeps
    // the front-by-convention slot.
    const out = try sortClasses(tst.allocator, "md:sr-only custom-class sr-only p-1", "");
    defer tst.allocator.free(out);
    try tst.expectEqualStrings("custom-class p-1 sr-only md:sr-only", out);
}

test "sortClasses: hover:b focus:p-1 a" {
    const out = try sortClasses(tst.allocator, "hover:b focus:p-1 a", "");
    defer tst.allocator.free(out);
    try tst.expectEqualStrings("hover:b a focus:p-1", out);
}
