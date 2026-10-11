//! The class book: every declaration a sheet holds, in one context, with its short name (an
//! atom), and every class as the atoms it is made of. Built once, when a sheet is built (the
//! admin's at build, an app's at its load); read by every render with no allocation.
//!
//! A page writes a class as its atoms' names: `size-4` is two (`width`, `height`), `px-4`
//! one. Identical declarations share a name across classes, so the sheet holds each once.
//! A merge is per atom: a later atom in the same context removes an earlier one of the same
//! property, or of a longhand it covers (`p-2` after `px-4`). A marker (`group/x`) keeps a
//! name of its own; a class the book does not hold (styled by hand-written CSS) is written
//! as it is and never conflicts.
const std = @import("std");
const compile = @import("compile.zig");
const sort = @import("sort.zig");
const theme = @import("theme.zig");

const Theme = theme.Theme;

/// Classes one attribute may hold after its parts are split.
pub const classes_max = 256;
/// Atoms one attribute may hold: its classes' declarations.
pub const atoms_max = classes_max * 8;

/// An atom's CSS, kept in a book just built for the sheet; empty in an embedded one.
pub const Rule = struct {
    at_rules: []const []const u8,
    selector: []const u8,
    important: bool,
    property: []const u8,
    value: []const u8,
    /// The first class holding it, for the Debug sheet's comment.
    class: []const u8,
};

pub const Book = struct {
    /// Each class, by id.
    classes: []const []const u8,
    /// A marker's name (`group/x`); empty for a class made of atoms.
    marker_names: []const []const u8,
    /// The atoms of class `id` are `class_atoms[atom_starts[id]..atom_starts[id + 1]]`.
    atom_starts: []const u32,
    class_atoms: []const u32,
    /// Open addressing over the class texts: a slot holds an id plus one; 0 is empty.
    class_slots: []const u32,
    /// Each atom's name, by id, in the sheet's cascade order.
    atom_names: []const []const u8,
    /// Each atom's context (at-rules, selector, importance) and property, as dense ids.
    atom_scopes: []const u16,
    atom_properties: []const u16,
    /// The longhands property `p` covers are `covers[cover_starts[p]..cover_starts[p + 1]]`.
    cover_starts: []const u32,
    covers: []const u16,
    rules: []const Rule = &.{},

    pub fn class_id(book: *const Book, class: []const u8) ?u32 {
        std.debug.assert(book.class_slots.len == 0 or std.math.isPowerOfTwo(book.class_slots.len));

        if (book.class_slots.len == 0) {
            return null;
        }

        const mask = book.class_slots.len - 1;
        var slot: usize = @intCast(std.hash.Wyhash.hash(0, class) & mask);

        for (0..book.class_slots.len) |_| {
            const held = book.class_slots[slot];

            if (held == 0) {
                return null;
            }

            if (std.mem.eql(u8, book.classes[held - 1], class)) {
                return held - 1;
            }

            slot = (slot + 1) & mask;
        }

        return null;
    }

    pub fn atoms_of(book: *const Book, id: u32) []const u32 {
        std.debug.assert(id < book.classes.len);

        return book.class_atoms[book.atom_starts[id]..book.atom_starts[id + 1]];
    }

    /// Whether property `short` covers `long` (`padding` covers `padding-left`).
    pub fn covered(book: *const Book, short: u16, long: u16) bool {
        if (short + 1 >= book.cover_starts.len) return false;

        const longhands = book.covers[book.cover_starts[short]..book.cover_starts[short + 1]];

        return std.mem.indexOfScalar(u16, longhands, long) != null;
    }

    /// A marker's name, when `class` is a marker the book holds.
    pub fn name_of(book: *const Book, class: []const u8) ?[]const u8 {
        const id = book.class_id(class) orelse return null;
        const name = book.marker_names[id];

        return if (name.len > 0) name else null;
    }

    /// `class` as a page writes it, alone: its atoms' names or its marker's, else itself.
    pub fn write_class(book: *const Book, writer: *std.Io.Writer, class: []const u8) !void {
        const id = book.class_id(class) orelse return escape(writer, class);

        if (book.marker_names[id].len > 0) {
            return writer.writeAll(book.marker_names[id]);
        }

        for (book.atoms_of(id), 0..) |atom, at| {
            if (at > 0) try writer.writeByte(' ');
            try writer.writeAll(book.atom_names[atom]);
        }
    }
};

pub const MergeError = error{TooManyClasses};

/// One attribute's classes after a merge: the atoms that survive, the markers, and the
/// classes the book does not hold, each in the order they came.
pub const Merged = struct {
    atoms: [atoms_max]u32 = undefined,
    atoms_len: u32 = 0,
    markers: [classes_max]u32 = undefined,
    markers_len: u32 = 0,
    raw: [classes_max][]const u8 = undefined,
    raw_len: u32 = 0,
};

/// `parts` (base, then variants, then the caller's own, each whitespace-separated) merged.
pub fn merge(book: *const Book, parts: []const []const u8, merged: *Merged) MergeError!void {
    std.debug.assert(merged.atoms_len == 0);
    std.debug.assert(merged.raw_len == 0);

    var removed: [atoms_max]bool = undefined;

    for (parts) |part| {
        var tokens = std.mem.tokenizeAny(u8, part, " \t\r\n");

        while (tokens.next()) |raw| {
            const id = book.class_id(raw) orelse {
                if (merged.raw_len == classes_max) return error.TooManyClasses;
                merged.raw[merged.raw_len] = raw;
                merged.raw_len += 1;
                continue;
            };

            if (book.marker_names[id].len > 0) {
                if (std.mem.indexOfScalar(u32, merged.markers[0..merged.markers_len], id) != null) continue;
                if (merged.markers_len == classes_max) return error.TooManyClasses;
                merged.markers[merged.markers_len] = id;
                merged.markers_len += 1;
                continue;
            }

            for (book.atoms_of(id)) |atom| {
                try add_atom(book, merged, &removed, atom);
            }
        }
    }

    var kept: u32 = 0;

    for (merged.atoms[0..merged.atoms_len], removed[0..merged.atoms_len]) |atom, gone| {
        if (!gone) {
            merged.atoms[kept] = atom;
            kept += 1;
        }
    }

    merged.atoms_len = kept;
}

/// `atom` after the ones held: it removes each earlier one it overrides, and is held once.
fn add_atom(book: *const Book, merged: *Merged, removed: *[atoms_max]bool, atom: u32) MergeError!void {
    const scope = book.atom_scopes[atom];
    const property = book.atom_properties[atom];

    for (merged.atoms[0..merged.atoms_len], removed[0..merged.atoms_len]) |earlier, *gone| {
        if (gone.*) continue;

        // The same declaration again: it is there already.
        if (earlier == atom) return;

        if (book.atom_scopes[earlier] != scope) continue;

        const other = book.atom_properties[earlier];

        if (other == property or book.covered(property, other)) {
            gone.* = true;
        }
    }

    if (merged.atoms_len == atoms_max) return error.TooManyClasses;

    merged.atoms[merged.atoms_len] = atom;
    removed[merged.atoms_len] = false;
    merged.atoms_len += 1;
}

/// `parts` merged and written as the page sends them: the surviving atoms' names, the
/// markers' names, then the classes the book does not hold, escaped for an attribute value.
pub fn write(book: *const Book, writer: *std.Io.Writer, parts: []const []const u8) !void {
    var merged: Merged = .{};

    try merge(book, parts, &merged);
    try write_merged(book, writer, &merged);
}

pub fn write_merged(book: *const Book, writer: *std.Io.Writer, merged: *const Merged) !void {
    std.debug.assert(merged.atoms_len <= atoms_max);

    var first = true;

    for (merged.atoms[0..merged.atoms_len]) |atom| {
        if (!first) try writer.writeByte(' ');
        try writer.writeAll(book.atom_names[atom]);
        first = false;
    }

    for (merged.markers[0..merged.markers_len]) |id| {
        if (!first) try writer.writeByte(' ');
        try writer.writeAll(book.marker_names[id]);
        first = false;
    }

    for (merged.raw[0..merged.raw_len]) |raw| {
        if (!first) try writer.writeByte(' ');
        try escape(writer, raw);
        first = false;
    }
}

/// `parts` merged into a class list owned by `allocator`.
pub fn text(book: *const Book, allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var merged: Merged = .{};

    try merge(book, parts, &merged);

    var counting: std.Io.Writer.Discarding = .init(&.{});

    try write_merged(book, &counting.writer, &merged);

    const out = try allocator.alloc(u8, @intCast(counting.fullCount()));
    var fixed: std.Io.Writer = .fixed(out);

    write_merged(book, &fixed, &merged) catch unreachable;
    std.debug.assert(fixed.end == out.len);

    return out;
}

fn escape(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |char| {
        switch (char) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(char),
        }
    }
}

// ── Building ────────────────────────────────────────────────────────────────

pub const Input = struct {
    /// Every class the sheet's sources name; repeats count towards shorter names.
    classes: []const []const u8,
    /// Classes a page writes as they are that are not in `classes` (hand-written CSS, a
    /// site's own): no name may be one of them.
    reserved: []const []const u8 = &.{},
};

pub const BuildError = error{ OutOfMemory, TooManyClasses, NotImplemented };

/// The book for `input`, with the rules its sheet is written from, owned by `arena`; the
/// resolver's temporaries go to `gpa`.
pub fn build(gpa: std.mem.Allocator, arena: std.mem.Allocator, t: Theme, input: Input) BuildError!Book {
    var counts: std.StringArrayHashMapUnmanaged(u32) = .empty;
    defer counts.deinit(gpa);
    var taken: std.StringHashMapUnmanaged(void) = .empty;
    defer taken.deinit(gpa);

    for (input.classes) |class| {
        try count(gpa, &counts, class);
    }

    for (input.reserved) |class| {
        try taken.put(gpa, class, {});
    }

    // Only classes a utility answers are in the book; the rest stay as they are, so no
    // name may be one of them.
    var held: std.ArrayList([]const u8) = .empty;
    defer held.deinit(gpa);
    var made: std.StringHashMapUnmanaged(compile.ClassAtoms) = .empty;
    defer made.deinit(gpa);

    for (counts.keys()) |class| {
        try taken.put(gpa, class, {});

        // A named group or peer (`group/row`) is a marker compound variants point at.
        if (is_marker(class)) {
            try made.put(gpa, class, .marker);
            try held.append(gpa, class);
            continue;
        }

        const atoms = compile.classAtoms(gpa, arena, t, class) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        } orelse continue;

        try made.put(gpa, class, atoms);
        try held.append(gpa, class);
    }

    const order = try cascade_order(gpa, t, held.items);
    defer gpa.free(order);

    const len: u32 = @intCast(order.len);
    const classes = try arena.alloc([]const u8, len);
    const marker_names = try arena.alloc([]const u8, len);
    const atom_starts = try arena.alloc(u32, len + 1);
    var class_atoms: std.ArrayList(u32) = .empty;
    var atom_ids: std.StringArrayHashMapUnmanaged(u32) = .empty;
    defer atom_ids.deinit(gpa);
    var rules: std.ArrayList(Rule) = .empty;
    var atom_uses: std.ArrayList(u32) = .empty;
    defer atom_uses.deinit(gpa);
    var scope_ids: std.StringHashMapUnmanaged(u16) = .empty;
    defer scope_ids.deinit(gpa);
    var property_ids: std.StringArrayHashMapUnmanaged(u16) = .empty;
    defer property_ids.deinit(gpa);
    var scopes: std.ArrayList(u16) = .empty;
    var properties: std.ArrayList(u16) = .empty;

    // Atoms take the cascade order of the first class holding them.
    for (order, 0..) |at, id| {
        const class = held.items[at];
        const uses = counts.get(class).?;

        classes[id] = class;
        marker_names[id] = "";
        atom_starts[id] = @intCast(class_atoms.items.len);

        const atoms = switch (made.get(class).?) {
            .marker => {
                marker_names[id] = "\x00";
                continue;
            },
            .atoms => |list| list,
        };

        for (atoms) |atom| {
            const key = try atom_key(arena, atom);
            const slot = try atom_ids.getOrPut(gpa, key);

            if (slot.found_existing) {
                atom_uses.items[slot.value_ptr.*] += uses;
            } else {
                slot.value_ptr.* = @intCast(rules.items.len);
                try atom_uses.append(gpa, uses);
                try rules.append(arena, .{
                    .at_rules = atom.at_rules,
                    .selector = atom.selector,
                    .important = atom.important,
                    .property = atom.property,
                    .value = atom.value,
                    .class = class,
                });
                try scopes.append(arena, try dense(gpa, &scope_ids, key[0 .. key.len - atom_tail_len(atom)]));
                try properties.append(arena, try dense_property(gpa, &property_ids, atom.property));
            }

            // A class lists an atom once.
            if (std.mem.indexOfScalar(u32, class_atoms.items[atom_starts[id]..], slot.value_ptr.*) == null) {
                try class_atoms.append(arena, slot.value_ptr.*);
            }
        }
    }

    atom_starts[len] = @intCast(class_atoms.items.len);

    var book: Book = .{
        .classes = classes,
        .marker_names = marker_names,
        .atom_starts = atom_starts,
        .class_atoms = class_atoms.items,
        .class_slots = try class_table(arena, classes),
        .atom_names = &.{},
        .atom_scopes = scopes.items,
        .atom_properties = properties.items,
        .cover_starts = &.{},
        .covers = &.{},
        .rules = rules.items,
    };

    try cover_table(arena, &book, property_ids.keys());
    try name_all(gpa, arena, &book, &counts, atom_uses.items, &taken);

    return book;
}

fn is_marker(class: []const u8) bool {
    for ([_][]const u8{ "group/", "peer/" }) |prefix| {
        if (std.mem.startsWith(u8, class, prefix) and class.len > prefix.len) return true;
    }

    return false;
}

/// What an atom is: its context, then its declaration. Two atoms with one key are one.
fn atom_key(arena: std.mem.Allocator, atom: compile.Atom) ![]const u8 {
    var key: std.ArrayList(u8) = .empty;

    for (atom.at_rules) |at_rule| {
        try key.appendSlice(arena, at_rule);
        try key.append(arena, '\x01');
    }

    try key.appendSlice(arena, atom.selector);
    try key.appendSlice(arena, if (atom.important) "\x01!" else "\x01");
    try key.append(arena, '\x01');
    try key.appendSlice(arena, atom.property);
    try key.append(arena, ':');
    try key.appendSlice(arena, atom.value);

    return key.items;
}

/// The declaration's part of `atom_key`: what follows the context.
fn atom_tail_len(atom: compile.Atom) usize {
    return 1 + atom.property.len + 1 + atom.value.len;
}

fn count(gpa: std.mem.Allocator, counts: *std.StringArrayHashMapUnmanaged(u32), class: []const u8) !void {
    std.debug.assert(class.len > 0);

    const slot = try counts.getOrPut(gpa, class);

    slot.value_ptr.* = if (slot.found_existing) slot.value_ptr.* + 1 else 1;
}

fn dense(gpa: std.mem.Allocator, ids: *std.StringHashMapUnmanaged(u16), key: []const u8) !u16 {
    const slot = try ids.getOrPut(gpa, key);

    if (!slot.found_existing) {
        if (ids.count() > std.math.maxInt(u16)) return error.TooManyClasses;
        slot.value_ptr.* = @intCast(ids.count() - 1);
    }

    return slot.value_ptr.*;
}

fn dense_property(gpa: std.mem.Allocator, ids: *std.StringArrayHashMapUnmanaged(u16), property: []const u8) !u16 {
    const slot = try ids.getOrPut(gpa, property);

    if (!slot.found_existing) {
        if (ids.count() > std.math.maxInt(u16)) return error.TooManyClasses;
        slot.value_ptr.* = @intCast(ids.count() - 1);
    }

    return slot.value_ptr.*;
}

/// The classes' indices in the sheet's cascade order (the order `compile` writes rules in).
fn cascade_order(gpa: std.mem.Allocator, t: Theme, classes: []const []const u8) ![]u32 {
    var index: std.StringHashMapUnmanaged(u32) = .empty;
    defer index.deinit(gpa);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);

    for (classes, 0..) |class, at| {
        try index.put(gpa, class, @intCast(at));

        if (at > 0) try joined.append(gpa, ' ');
        try joined.appendSlice(gpa, class);
    }

    const sorted = sort.sortClassesWithTheme(gpa, joined.items, t) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotImplemented => return error.NotImplemented,
    };
    defer gpa.free(sorted);

    const order = try gpa.alloc(u32, classes.len);
    var len: usize = 0;
    var tokens = std.mem.tokenizeScalar(u8, sorted, ' ');

    while (tokens.next()) |class| {
        const at = index.get(class) orelse continue;

        order[len] = at;
        len += 1;
    }

    std.debug.assert(len == classes.len);

    return order;
}

fn class_table(arena: std.mem.Allocator, classes: []const []const u8) ![]u32 {
    const slots = try arena.alloc(u32, table_len(classes.len));

    @memset(slots, 0);

    for (classes, 0..) |class, id| {
        const mask = slots.len - 1;
        var slot: usize = @intCast(std.hash.Wyhash.hash(0, class) & mask);

        while (slots[slot] != 0) slot = (slot + 1) & mask;

        slots[slot] = @intCast(id + 1);
    }

    return slots;
}

/// Twice the entries, a power of two, so probes stay short.
fn table_len(entries: usize) usize {
    return std.math.ceilPowerOfTwoAssert(usize, @max(entries * 2, 2));
}

/// Which of `properties` (by dense id) each covers.
fn cover_table(arena: std.mem.Allocator, book: *Book, properties: []const []const u8) !void {
    const starts = try arena.alloc(u32, properties.len + 1);
    var covers: std.ArrayList(u16) = .empty;

    for (properties, 0..) |short, id| {
        starts[id] = @intCast(covers.items.len);

        for (properties, 0..) |long, other| {
            if (other != id and shorthand_covers(short, long)) {
                try covers.append(arena, @intCast(other));
            }
        }
    }

    starts[properties.len] = @intCast(covers.items.len);
    book.cover_starts = starts;
    book.covers = covers.items;
}

/// Whether setting `short` sets `long` too: `padding` sets `padding-left`, `padding-inline`
/// sets `padding-left` and `padding-right`, `border-radius` each corner.
pub fn shorthand_covers(short: []const u8, long: []const u8) bool {
    const Family = struct { short: []const u8, longs: []const []const u8 };
    const sides = [_][]const u8{
        "-top",         "-right",     "-bottom",       "-left",
        "-inline",      "-block",     "-inline-start", "-inline-end",
        "-block-start", "-block-end",
    };
    const families = [_][]const u8{ "padding", "margin", "scroll-margin", "scroll-padding" };

    for (families) |family| {
        if (std.mem.eql(u8, short, family)) {
            for (sides) |side| if (suffixed(long, family, side)) return true;
            return false;
        }

        if (suffixed(short, family, "-inline")) {
            return suffixed(long, family, "-left") or suffixed(long, family, "-right") or
                suffixed(long, family, "-inline-start") or suffixed(long, family, "-inline-end");
        }

        if (suffixed(short, family, "-block")) {
            return suffixed(long, family, "-top") or suffixed(long, family, "-bottom") or
                suffixed(long, family, "-block-start") or suffixed(long, family, "-block-end");
        }
    }

    const explicit = [_]Family{
        .{ .short = "inset", .longs = &.{ "top", "right", "bottom", "left", "inset-inline", "inset-block", "inset-inline-start", "inset-inline-end", "inset-block-start", "inset-block-end" } },
        .{ .short = "inset-inline", .longs = &.{ "left", "right", "inset-inline-start", "inset-inline-end" } },
        .{ .short = "inset-block", .longs = &.{ "top", "bottom", "inset-block-start", "inset-block-end" } },
        .{ .short = "border-radius", .longs = &.{ "border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius", "border-start-start-radius", "border-start-end-radius", "border-end-start-radius", "border-end-end-radius" } },
        .{ .short = "gap", .longs = &.{ "row-gap", "column-gap" } },
        .{ .short = "overflow", .longs = &.{ "overflow-x", "overflow-y" } },
        .{ .short = "overscroll-behavior", .longs = &.{ "overscroll-behavior-x", "overscroll-behavior-y" } },
        .{ .short = "place-content", .longs = &.{ "align-content", "justify-content" } },
        .{ .short = "place-items", .longs = &.{ "align-items", "justify-items" } },
        .{ .short = "place-self", .longs = &.{ "align-self", "justify-self" } },
        .{ .short = "flex", .longs = &.{ "flex-grow", "flex-shrink", "flex-basis" } },
        .{ .short = "grid-column", .longs = &.{ "grid-column-start", "grid-column-end" } },
        .{ .short = "grid-row", .longs = &.{ "grid-row-start", "grid-row-end" } },
    };

    for (explicit) |family| {
        if (!std.mem.eql(u8, short, family.short)) continue;
        for (family.longs) |known| if (std.mem.eql(u8, long, known)) return true;
        return false;
    }

    // `border-width` sets each side's width; `border-inline-width` the inline sides'.
    for ([_][]const u8{ "-width", "-color", "-style" }) |part| {
        if (!std.mem.endsWith(u8, short, part) or !std.mem.endsWith(u8, long, part)) continue;
        if (!std.mem.startsWith(u8, short, "border") or !std.mem.startsWith(u8, long, "border-")) continue;

        const short_side = short["border".len .. short.len - part.len];
        const long_side = long["border".len .. long.len - part.len];

        if (short_side.len == 0) return long_side.len > 0;
        if (std.mem.eql(u8, short_side, "-inline")) {
            return std.mem.eql(u8, long_side, "-left") or std.mem.eql(u8, long_side, "-right") or
                std.mem.eql(u8, long_side, "-inline-start") or std.mem.eql(u8, long_side, "-inline-end");
        }
        if (std.mem.eql(u8, short_side, "-block")) {
            return std.mem.eql(u8, long_side, "-top") or std.mem.eql(u8, long_side, "-bottom") or
                std.mem.eql(u8, long_side, "-block-start") or std.mem.eql(u8, long_side, "-block-end");
        }
    }

    return false;
}

fn suffixed(word: []const u8, prefix: []const u8, suffix: []const u8) bool {
    return word.len == prefix.len + suffix.len and std.mem.startsWith(u8, word, prefix) and
        std.mem.endsWith(u8, word, suffix);
}

/// Names for every atom and marker, the most used shortest, none of them `taken`.
fn name_all(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    book: *Book,
    counts: *const std.StringArrayHashMapUnmanaged(u32),
    atom_uses: []const u32,
    taken: *const std.StringHashMapUnmanaged(void),
) !void {
    const Item = struct {
        uses: u32,
        /// Atoms first by id, then classes (markers) by id.
        index: u32,
    };
    const atom_len: u32 = @intCast(atom_uses.len);
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(gpa);

    for (atom_uses, 0..) |uses, atom| {
        try items.append(gpa, .{
            .uses = uses,
            .index = @intCast(atom),
        });
    }

    for (book.classes, 0..) |class, id| {
        if (book.marker_names[id].len == 0) continue;
        try items.append(gpa, .{
            .uses = counts.get(class) orelse 1,
            .index = atom_len + @as(u32, @intCast(id)),
        });
    }

    std.mem.sort(Item, items.items, {}, struct {
        fn more(_: void, a: Item, b: Item) bool {
            if (a.uses != b.uses) return a.uses > b.uses;
            return a.index < b.index;
        }
    }.more);

    const atom_names = try arena.alloc([]const u8, atom_len);
    const marker_names: [][]const u8 = @constCast(book.marker_names);
    var next: u64 = 0;

    for (items.items) |item| {
        const name = try fresh_name(arena, &next, taken);

        if (item.index < atom_len) {
            atom_names[item.index] = name;
        } else {
            marker_names[item.index - atom_len] = name;
        }
    }

    book.atom_names = atom_names;
}

const first_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
const rest_chars = first_chars ++ "0123456789_";

/// The `next`th name in the sequence a, b, … Z, aa, ab, …, skipping any that is `taken`.
fn fresh_name(
    arena: std.mem.Allocator,
    next: *u64,
    taken: *const std.StringHashMapUnmanaged(void),
) ![]const u8 {
    while (true) {
        var buffer: [16]u8 = undefined;
        const name = spelled(next.*, &buffer);

        next.* += 1;

        if (!taken.contains(name)) {
            return arena.dupe(u8, name);
        }
    }
}

fn spelled(index: u64, buffer: *[16]u8) []const u8 {
    var rest = index;
    var span: u64 = first_chars.len;
    var len: usize = 1;

    while (rest >= span) {
        rest -= span;
        span *= rest_chars.len;
        len += 1;
    }

    std.debug.assert(len <= buffer.len);

    var at = len;

    while (at > 1) {
        at -= 1;
        buffer[at] = rest_chars[@intCast(rest % rest_chars.len)];
        rest /= rest_chars.len;
    }

    buffer[0] = first_chars[@intCast(rest)];

    return buffer[0..len];
}

/// Each `.class` a stylesheet selects (hand-written CSS a page's classes may meet): what a
/// book's `reserved` takes, so no name is one of them.
pub fn selectedClasses(
    allocator: std.mem.Allocator,
    css: []const u8,
    out: *std.ArrayList([]const u8),
) error{OutOfMemory}!void {
    var at: usize = 0;

    while (std.mem.indexOfScalarPos(u8, css, at, '.')) |dot| {
        var end = dot + 1;

        while (end < css.len and (std.ascii.isAlphanumeric(css[end]) or css[end] == '-' or css[end] == '_')) {
            end += 1;
        }

        if (end > dot + 1 and !std.ascii.isDigit(css[dot + 1])) {
            try out.append(allocator, css[dot + 1 .. end]);
        }

        at = end;
    }
}

/// The book as the browser module a page imports before its stores, which installs it in
/// PublrJS's merge (`useClassBook`), imported from `merge_path`.
pub fn writeScript(book: *const Book, writer: *std.Io.Writer, merge_path: []const u8) !void {
    try writer.print("import {{ useClassBook }} from \"{s}\";\nuseClassBook(", .{merge_path});
    try writeJson(book, writer);
    try writer.writeAll(");\n");
}

/// `html` with every `class` attribute's names read back as Tailwind: each element's atoms
/// as the fewest classes holding exactly them, markers as their classes, the rest as they
/// are. What a page says, for a person, an agent or a test.
pub fn decode(book: *const Book, allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var names: std.StringHashMapUnmanaged(Named) = .empty;
    defer names.deinit(allocator);

    for (book.atom_names, 0..) |name, atom| try names.put(allocator, name, .{ .atom = @intCast(atom) });
    for (book.marker_names, 0..) |name, id| {
        if (name.len > 0) try names.put(allocator, name, .{ .marker = @intCast(id) });
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const opening = "class=\"";
    var rest = html;

    while (std.mem.indexOf(u8, rest, opening)) |at| {
        const value_start = at + opening.len;
        const value_end = std.mem.indexOfScalarPos(u8, rest, value_start, '"') orelse break;

        try out.appendSlice(allocator, rest[0..value_start]);
        try decode_value(book, allocator, &names, rest[value_start..value_end], &out);
        try out.append(allocator, '"');
        rest = rest[value_end + 1 ..];
    }

    try out.appendSlice(allocator, rest);

    return out.toOwnedSlice(allocator);
}

const Named = union(enum) {
    atom: u32,
    marker: u32,
};

fn decode_value(
    book: *const Book,
    allocator: std.mem.Allocator,
    names: *const std.StringHashMapUnmanaged(Named),
    value: []const u8,
    out: *std.ArrayList(u8),
) !void {
    var atoms: std.ArrayList(u32) = .empty;
    defer atoms.deinit(allocator);
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(allocator);
    var tokens = std.mem.tokenizeScalar(u8, value, ' ');

    while (tokens.next()) |name| {
        const named = names.get(name) orelse {
            try words.append(allocator, name);
            continue;
        };

        switch (named) {
            .atom => |atom| try atoms.append(allocator, atom),
            .marker => |id| try words.append(allocator, book.classes[id]),
        }
    }

    // The classes whose atoms are all here, those holding the most first, each taken
    // while it holds an atom not yet read.
    var candidates: std.ArrayList(u32) = .empty;
    defer candidates.deinit(allocator);

    for (book.classes, 0..) |_, id| {
        const held = book.atoms_of(@intCast(id));
        if (held.len == 0) continue;
        for (held) |atom| {
            if (std.mem.indexOfScalar(u32, atoms.items, atom) == null) break;
        } else try candidates.append(allocator, @intCast(id));
    }

    std.mem.sort(u32, candidates.items, book, struct {
        fn more(b: *const Book, x: u32, y: u32) bool {
            const a = b.atoms_of(x).len;
            const c = b.atoms_of(y).len;
            return if (a != c) a > c else x < y;
        }
    }.more);

    var read = try allocator.alloc(bool, atoms.items.len);
    defer allocator.free(read);
    @memset(read, false);
    var chosen: std.ArrayList(u32) = .empty;
    defer chosen.deinit(allocator);

    for (candidates.items) |id| {
        var adds = false;
        for (book.atoms_of(id)) |atom| {
            const at = std.mem.indexOfScalar(u32, atoms.items, atom).?;
            if (!read[at]) adds = true;
        }
        if (!adds) continue;
        for (book.atoms_of(id)) |atom| read[std.mem.indexOfScalar(u32, atoms.items, atom).?] = true;
        try chosen.append(allocator, id);
    }

    // An atom left over (its class's other atoms overridden: `text-4xl leading-tight`) is
    // read as the smallest class holding it.
    for (atoms.items, read) |atom, *done| {
        if (done.*) continue;

        var best: ?u32 = null;

        for (0..book.classes.len) |id| {
            const held = book.atoms_of(@intCast(id));
            if (std.mem.indexOfScalar(u32, held, atom) == null) continue;
            if (best == null or held.len < book.atoms_of(best.?).len) best = @intCast(id);
        }

        const id = best orelse continue;

        done.* = true;
        if (std.mem.indexOfScalar(u32, chosen.items, id) == null) try chosen.append(allocator, id);
    }

    // In the sheet's (cascade) order, as Tailwind writes them.
    std.mem.sort(u32, chosen.items, {}, std.sort.asc(u32));

    var first = true;

    for (chosen.items) |id| {
        if (!first) try out.append(allocator, ' ');
        try out.appendSlice(allocator, book.classes[id]);
        first = false;
    }

    for (atoms.items, read) |atom, done| {
        if (done) continue;
        if (!first) try out.append(allocator, ' ');
        try out.appendSlice(allocator, book.atom_names[atom]);
        first = false;
    }

    for (words.items) |word| {
        if (!first) try out.append(allocator, ' ');
        try out.appendSlice(allocator, word);
        first = false;
    }
}

/// The book as `writeJson` wrote it, owned by `arena`.
pub fn fromJson(arena: std.mem.Allocator, json: []const u8) !Book {
    const Data = struct {
        classes: []const std.json.Value,
        atoms: []const std.json.Value,
        covers: []const std.json.Value,
    };
    const data = try std.json.parseFromSliceLeaky(Data, arena, json, .{});
    const len = data.classes.len;
    const classes = try arena.alloc([]const u8, len);
    const marker_names = try arena.alloc([]const u8, len);
    const atom_starts = try arena.alloc(u32, len + 1);
    var class_atoms: std.ArrayList(u32) = .empty;

    for (data.classes, 0..) |row, id| {
        const fields = row.array.items;

        classes[id] = fields[0].string;
        marker_names[id] = fields[1].string;
        atom_starts[id] = @intCast(class_atoms.items.len);

        for (fields[2].array.items) |atom| try class_atoms.append(arena, @intCast(atom.integer));
    }

    atom_starts[len] = @intCast(class_atoms.items.len);

    const atom_names = try arena.alloc([]const u8, data.atoms.len);
    const atom_scopes = try arena.alloc(u16, data.atoms.len);
    const atom_properties = try arena.alloc(u16, data.atoms.len);
    var property_count: usize = 0;

    for (data.atoms, 0..) |row, atom| {
        const fields = row.array.items;

        atom_names[atom] = fields[0].string;
        atom_scopes[atom] = @intCast(fields[1].integer);
        atom_properties[atom] = @intCast(fields[2].integer);
        property_count = @max(property_count, atom_properties[atom] + 1);
    }

    const cover_starts = try arena.alloc(u32, property_count + 1);
    var covers: std.ArrayList(u16) = .empty;
    var listed: std.AutoHashMapUnmanaged(u16, []const std.json.Value) = .empty;

    for (data.covers) |row| {
        const fields = row.array.items;
        try listed.put(arena, @intCast(fields[0].integer), fields[1].array.items);
    }

    for (0..property_count) |property| {
        cover_starts[property] = @intCast(covers.items.len);
        if (listed.get(@intCast(property))) |longs| {
            for (longs) |long| try covers.append(arena, @intCast(long.integer));
        }
    }

    cover_starts[property_count] = @intCast(covers.items.len);

    return .{
        .classes = classes,
        .marker_names = marker_names,
        .atom_starts = atom_starts,
        .class_atoms = class_atoms.items,
        .class_slots = try class_table(arena, classes),
        .atom_names = atom_names,
        .atom_scopes = atom_scopes,
        .atom_properties = atom_properties,
        .cover_starts = cover_starts,
        .covers = covers.items,
    };
}

// ── Sources ─────────────────────────────────────────────────────────────────

/// The book as Zig declarations a module embeds (`book.zig`'s fields, by name), so a build
/// carries it with no work at startup.
pub fn writeZig(book: *const Book, writer: *std.Io.Writer) !void {
    try writer.writeAll("//! Written by the Publr JIT: the class book of one sheet.\n");
    try write_strings(writer, "classes", book.classes);
    try write_strings(writer, "marker_names", book.marker_names);
    try write_numbers(u32, writer, "atom_starts", book.atom_starts);
    try write_numbers(u32, writer, "class_atoms", book.class_atoms);
    try write_numbers(u32, writer, "class_slots", book.class_slots);
    try write_strings(writer, "atom_names", book.atom_names);
    try write_numbers(u16, writer, "atom_scopes", book.atom_scopes);
    try write_numbers(u16, writer, "atom_properties", book.atom_properties);
    try write_numbers(u32, writer, "cover_starts", book.cover_starts);
    try write_numbers(u16, writer, "covers", book.covers);
}

fn write_strings(writer: *std.Io.Writer, name: []const u8, values: []const []const u8) !void {
    try writer.print("pub const {s} = [_][]const u8{{\n", .{name});

    for (values) |value| {
        try writer.writeAll("    \"");
        try std.zig.stringEscape(value, writer);
        try writer.writeAll("\",\n");
    }

    try writer.writeAll("};\n");
}

fn write_numbers(comptime T: type, writer: *std.Io.Writer, name: []const u8, values: []const T) !void {
    try writer.print("pub const {s} = [_]{s}{{", .{ name, @typeName(T) });

    for (values, 0..) |value, at| {
        if (at % 16 == 0) try writer.writeAll("\n   ");
        try writer.print(" {d},", .{value});
    }

    try writer.writeAll("\n};\n");
}

/// The book as JSON for the browser's merge: `{"classes":[[class,marker,[atom…]]…],
/// "atoms":[[name,scope,property]…],"covers":[[property,[longhand…]]…]}`.
pub fn writeJson(book: *const Book, writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"classes\":[");

    for (book.classes, 0..) |class, id| {
        if (id > 0) try writer.writeByte(',');
        try writer.writeByte('[');
        try std.json.Stringify.encodeJsonString(class, .{}, writer);
        try writer.writeByte(',');
        try std.json.Stringify.encodeJsonString(book.marker_names[id], .{}, writer);
        try writer.writeAll(",[");

        for (book.atoms_of(@intCast(id)), 0..) |atom, at| {
            if (at > 0) try writer.writeByte(',');
            try writer.print("{d}", .{atom});
        }

        try writer.writeAll("]]");
    }

    try writer.writeAll("],\"atoms\":[");

    for (book.atom_names, 0..) |name, atom| {
        if (atom > 0) try writer.writeByte(',');
        try writer.writeByte('[');
        try std.json.Stringify.encodeJsonString(name, .{}, writer);
        try writer.print(",{d},{d}]", .{ book.atom_scopes[atom], book.atom_properties[atom] });
    }

    try writer.writeAll("],\"covers\":[");

    var first = true;

    for (0..book.cover_starts.len -| 1) |property| {
        const longs = book.covers[book.cover_starts[property]..book.cover_starts[property + 1]];
        if (longs.len == 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("[{d},[", .{property});
        for (longs, 0..) |long, at| {
            if (at > 0) try writer.writeByte(',');
            try writer.print("{d}", .{long});
        }
        try writer.writeAll("]]");
    }

    try writer.writeAll("]}");
}

// ── Tests ───────────────────────────────────────────────────────────────────

const test_theme: Theme = .{
    .tokens = &.{
        .{
            .name = "spacing",
            .value = "0.25rem",
        },
        .{
            .name = "color-red-500",
            .value = "red",
        },
        .{
            .name = "color-blue-500",
            .value = "blue",
        },
        .{
            .name = "radius-md",
            .value = "0.375rem",
        },
        .{
            .name = "radius-lg",
            .value = "0.5rem",
        },
    },
};

fn test_book(arena: std.mem.Allocator, input: Input) !Book {
    return build(std.testing.allocator, arena, test_theme, input);
}

/// The names `parts` are written as, sorted.
fn written(book: *const Book, arena: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    const out = try text(book, arena, parts);
    var names: std.ArrayList([]const u8) = .empty;
    var tokens = std.mem.tokenizeScalar(u8, out, ' ');

    while (tokens.next()) |name| try names.append(arena, name);

    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);

    return std.mem.join(arena, " ", names.items);
}

fn all_classes(arena: std.mem.Allocator, cases: []const [2][]const u8) ![]const []const u8 {
    var classes: std.ArrayList([]const u8) = .empty;

    for (cases) |case| {
        for (case) |side| {
            var tokens = std.mem.tokenizeScalar(u8, side, ' ');
            while (tokens.next()) |class| try classes.append(arena, class);
        }
    }

    return classes.items;
}

test "a merge keeps the later declaration of each property, and a shorthand its longhands'" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Each case merged writes the same names as the classes on its right.
    const cases = [_][2][]const u8{
        .{ "w-8 px-2.5 px-0", "w-8 px-0" },
        .{ "bg-red-500 bg-blue-500", "bg-blue-500" },
        .{ "hover:bg-red-500 hover:bg-blue-500", "hover:bg-blue-500" },
        .{ "p-4 px-2", "p-4 px-2" },
        .{ "px-2 p-4", "p-4" },
        .{ "hover:px-4 focus:px-2", "hover:px-4 focus:px-2" },
        .{ "p-4! p-2", "p-4! p-2" },
        .{ "size-4 w-8", "h-4 w-8" },
        .{ "flex hand-made flex", "flex hand-made" },
        .{ "rounded-t-md rounded-lg", "rounded-lg" },
        .{ "gap-x-2 gap-4", "gap-4" },
    };
    const book = try test_book(arena, .{
        .classes = try all_classes(arena, &cases),
    });

    for (cases) |case| {
        try std.testing.expectEqualStrings(
            try written(&book, arena, &.{case[1]}),
            try written(&book, arena, &.{case[0]}),
        );
    }
}

test "one declaration is one name, shared by the classes that hold it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const book = try test_book(arena_state.allocator(), .{
        .classes = &.{ "w-4", "h-4", "size-4", "px-4" },
    });
    const size = book.atoms_of(book.class_id("size-4").?);

    try std.testing.expectEqual(@as(usize, 2), size.len);
    try std.testing.expect(std.mem.indexOfScalar(u32, size, book.atoms_of(book.class_id("w-4").?)[0]) != null);
    try std.testing.expect(std.mem.indexOfScalar(u32, size, book.atoms_of(book.class_id("h-4").?)[0]) != null);
    // width, height, and px-4's two sides.
    try std.testing.expectEqual(@as(usize, 4), book.atom_names.len);
}

test "a class no utility answers keeps its text and gets no name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const book = try test_book(arena_state.allocator(), .{
        .classes = &.{ "flex", "drawer-enter" },
    });
    const out = try text(&book, arena_state.allocator(), &.{"flex drawer-enter"});

    try std.testing.expect(book.class_id("drawer-enter") == null);
    try std.testing.expectEqualStrings("a drawer-enter", out);
}

test "a group marker keeps a name of its own" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const book = try test_book(arena, .{
        .classes = &.{ "group/disclosure", "flex", "group-hover/disclosure:flex" },
    });
    const marker = book.name_of("group/disclosure").?;
    const out = try text(&book, arena, &.{"group/disclosure flex"});

    try std.testing.expect(std.mem.indexOf(u8, out, marker) != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, " ") + 1);
}

test "no name is a class a page writes as it is" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const book = try test_book(arena_state.allocator(), .{
        .classes = &.{ "flex", "a" },
        .reserved = &.{"b"},
    });

    for (book.atom_names) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "a"));
        try std.testing.expect(!std.mem.eql(u8, name, "b"));
    }
}

test "names run a … Z, then two characters" {
    var buffer: [16]u8 = undefined;

    try std.testing.expectEqualStrings("a", spelled(0, &buffer));
    try std.testing.expectEqualStrings("Z", spelled(51, &buffer));
    try std.testing.expectEqualStrings("aa", spelled(52, &buffer));
    try std.testing.expectEqualStrings("a_", spelled(52 + 62, &buffer));
    try std.testing.expectEqualStrings("ba", spelled(52 + 63, &buffer));
    try std.testing.expectEqualStrings("aaa", spelled(52 + 52 * 63, &buffer));
}

test "decode reads a page's names back as the fewest classes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const book = try test_book(arena, .{
        .classes = &.{ "flex", "w-4", "h-4", "size-4", "px-4" },
    });
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writer.writeAll("<p class=\"");
    try write(&book, &writer, &.{"size-4 flex"});
    try writer.writeAll("\">a</p><i class=\"");
    try write(&book, &writer, &.{"px-4 hand-made"});
    try writer.writeAll("\">b</i>");

    const page = try decode(&book, arena, writer.buffered());

    try std.testing.expectEqualStrings(
        "<p class=\"flex size-4\">a</p><i class=\"px-4 hand-made\">b</i>",
        page,
    );
}

test "the book survives as Zig and as JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const book = try test_book(arena, .{
        .classes = &.{ "flex", "px-2", "p-4", "group/x" },
    });
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeZig(&book, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "pub const covers") != null);

    writer = .fixed(&buffer);
    try writeJson(&book, &writer);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "{\"classes\":[[\""));

    const read = try fromJson(arena, writer.buffered());

    try std.testing.expectEqualStrings(book.atom_names[0], read.atom_names[0]);
    try std.testing.expectEqualStrings(
        try text(&book, arena, &.{"px-2 p-4 group/x"}),
        try text(&read, arena, &.{"px-2 p-4 group/x"}),
    );
}

test "a shorthand covers its sides" {
    try std.testing.expect(shorthand_covers("padding", "padding-left"));
    try std.testing.expect(shorthand_covers("padding-inline", "padding-right"));
    try std.testing.expect(!shorthand_covers("padding-inline", "padding-top"));
    try std.testing.expect(shorthand_covers("border-width", "border-top-width"));
    try std.testing.expect(shorthand_covers("border-inline-width", "border-left-width"));
    try std.testing.expect(!shorthand_covers("border-width", "border-top-color"));
    try std.testing.expect(shorthand_covers("inset", "top"));
    try std.testing.expect(!shorthand_covers("flex", "flex-direction"));
}

