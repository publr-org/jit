//! Tailwind-aware class merging owned by Publr's Zig class engine.
//!
//! The utility resolver is the source of truth: a class conflicts with an
//! earlier class only when both live in the same variant/important scope and
//! the later utility owns every CSS property owned by the earlier utility.
//! Unknown/non-Tailwind classes are preserved verbatim.

const std = @import("std");
const candidate = @import("candidate.zig");
const utilities = @import("utilities.zig");
const theme = @import("theme.zig");

const Theme = theme.Theme;

const Entry = struct {
    raw: []const u8,
    scope: u64 = 0,
    properties: std.ArrayList(u64) = .empty,
    removed: bool = false,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        self.properties.deinit(allocator);
    }
};

/// Merge whitespace-separated class parts. The returned slice is owned by
/// `allocator`. Parts are ordered base → variants/state → caller overrides.
pub fn mergeClasses(
    allocator: std.mem.Allocator,
    active_theme: Theme,
    parts: []const []const u8,
) ![]u8 {
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    for (parts) |part| {
        var tokens = std.mem.tokenizeAny(u8, part, " \t\r\n");
        while (tokens.next()) |raw| {
            var incoming = try resolveEntry(allocator, active_theme, raw);
            errdefer incoming.deinit(allocator);

            if (incoming.properties.items.len != 0) {
                for (entries.items) |*existing| {
                    if (existing.removed or existing.scope != incoming.scope) continue;
                    if (ownsAll(incoming.properties.items, existing.properties.items)) {
                        existing.removed = true;
                    }
                }
            }
            try entries.append(allocator, incoming);
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (entries.items) |entry| {
        if (entry.removed) continue;
        if (out.items.len != 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, entry.raw);
    }
    return out.toOwnedSlice(allocator);
}

/// Write the conflict groups of `classes` as JSON:
///   { "<class>": ["<scope>", ["<property>", …]], … }
/// `scope` and each `property` are the same 64-bit hashes `mergeClasses` compares
/// (decimal strings — they exceed 2^53), so a runtime holding this table merges
/// EXACTLY like this engine without carrying the resolver: same scope, and the
/// later class owns every property of the earlier one ⇒ the earlier one drops.
/// A class with no properties never conflicts (unknown / non-Tailwind classes).
pub fn writeClassGroups(
    allocator: std.mem.Allocator,
    active_theme: Theme,
    classes: []const []const u8,
    writer: *std.Io.Writer,
) !void {
    try writer.writeByte('{');
    var first = true;
    for (classes) |raw| {
        var entry = try resolveEntry(allocator, active_theme, raw);
        defer entry.deinit(allocator);
        if (!first) try writer.writeByte(',');
        first = false;
        try std.json.Stringify.encodeJsonString(raw, .{}, writer);
        try writer.print(":[\"{d}\",[", .{entry.scope});
        for (entry.properties.items, 0..) |property, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.print("\"{d}\"", .{property});
        }
        try writer.writeAll("]]");
    }
    try writer.writeByte('}');
}

fn resolveEntry(allocator: std.mem.Allocator, active_theme: Theme, raw: []const u8) !Entry {
    var entry = Entry{ .raw = raw, .scope = scopeHash(raw) };
    errdefer entry.deinit(allocator);

    const candidates = try candidate.parseCandidate(allocator, raw);
    defer candidate.freeCandidates(allocator, candidates);

    for (candidates) |cand| {
        const resolved = try utilities.resolveCandidate(allocator, active_theme, cand);
        if (resolved == null) continue;
        defer utilities.freeResolvedUtility(allocator, resolved.?);

        const namespace: []const u8 = switch (cand) {
            // Tailwind deliberately keeps arbitrary properties independent
            // from named utilities (`p-2 [padding:1px]`).
            .arbitrary => "arbitrary:",
            else => "utility:",
        };
        const suffix = resolved.?.selector_suffix orelse "";
        for (resolved.?.declarations) |declaration| {
            try appendProperty(&entry.properties, allocator, namespace, suffix, declaration.property);
        }
        break;
    }
    return entry;
}

fn scopeHash(raw: []const u8) u64 {
    var bracket_depth: usize = 0;
    var paren_depth: usize = 0;
    var base_start: usize = 0;
    for (raw, 0..) |byte, index| {
        switch (byte) {
            '[' => bracket_depth += 1,
            ']' => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            ':' => if (bracket_depth == 0 and paren_depth == 0) {
                base_start = index + 1;
            },
            else => {},
        }
    }
    const important = raw.len > base_start and
        (raw[base_start] == '!' or raw[raw.len - 1] == '!');
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(raw[0..base_start]);
    hasher.update(if (important) "!" else "");
    return hasher.final();
}

fn propertyHash(namespace: []const u8, suffix: []const u8, property: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(namespace);
    hasher.update(suffix);
    hasher.update("\x00");
    hasher.update(property);
    return hasher.final();
}

fn appendOne(
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
    namespace: []const u8,
    suffix: []const u8,
    property: []const u8,
) !void {
    const value = propertyHash(namespace, suffix, property);
    if (std.mem.indexOfScalar(u64, out.items, value) == null) try out.append(allocator, value);
}

fn appendProperty(
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
    namespace: []const u8,
    suffix: []const u8,
    property: []const u8,
) !void {
    const expansion = shorthandExpansion(property) orelse {
        try appendOne(out, allocator, namespace, suffix, property);
        return;
    };
    for (expansion) |longhand| try appendOne(out, allocator, namespace, suffix, longhand);
}

fn shorthandExpansion(property: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, property, "padding")) return &.{ "padding-top", "padding-right", "padding-bottom", "padding-left" };
    if (std.mem.eql(u8, property, "margin")) return &.{ "margin-top", "margin-right", "margin-bottom", "margin-left" };
    if (std.mem.eql(u8, property, "inset")) return &.{ "top", "right", "bottom", "left" };
    if (std.mem.eql(u8, property, "overflow")) return &.{ "overflow-x", "overflow-y" };
    if (std.mem.eql(u8, property, "overscroll-behavior")) return &.{ "overscroll-behavior-x", "overscroll-behavior-y" };
    if (std.mem.eql(u8, property, "gap")) return &.{ "row-gap", "column-gap" };
    if (std.mem.eql(u8, property, "scroll-padding")) return &.{ "scroll-padding-top", "scroll-padding-right", "scroll-padding-bottom", "scroll-padding-left" };
    if (std.mem.eql(u8, property, "scroll-margin")) return &.{ "scroll-margin-top", "scroll-margin-right", "scroll-margin-bottom", "scroll-margin-left" };
    if (std.mem.eql(u8, property, "border-radius")) return &.{ "border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius" };
    if (std.mem.eql(u8, property, "border-width")) return &.{ "border-top-width", "border-right-width", "border-bottom-width", "border-left-width" };
    if (std.mem.eql(u8, property, "border-color")) return &.{ "border-top-color", "border-right-color", "border-bottom-color", "border-left-color" };
    if (std.mem.eql(u8, property, "border-style")) return &.{ "border-top-style", "border-right-style", "border-bottom-style", "border-left-style" };
    return null;
}

fn ownsAll(incoming: []const u64, existing: []const u64) bool {
    if (existing.len == 0 or incoming.len < existing.len) return false;
    for (existing) |property| {
        if (std.mem.indexOfScalar(u64, incoming, property) == null) return false;
    }
    return true;
}

const test_theme: Theme = .{ .tokens = &.{
    .{ .name = "spacing", .value = "0.25rem" },
    .{ .name = "color-red-500", .value = "red" },
    .{ .name = "color-blue-500", .value = "blue" },
    .{ .name = "text-sm", .value = "0.875rem" },
    .{ .name = "text-sm--line-height", .value = "1.25rem" },
    .{ .name = "text-lg", .value = "1.125rem" },
    .{ .name = "text-lg--line-height", .value = "1.75rem" },
    .{ .name = "radius", .value = "0.25rem" },
} };

fn expectMerge(input: []const u8, expected: []const u8) !void {
    const merged = try mergeClasses(std.testing.allocator, test_theme, &.{input});
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqualStrings(expected, merged);
}

test "caller utility wins within the same class group" {
    try expectMerge("w-8 px-2.5 px-0", "w-8 px-0");
    try expectMerge("bg-red-500 bg-blue-500", "bg-blue-500");
    try expectMerge("hover:bg-red-500 hover:bg-blue-500", "hover:bg-blue-500");
}

test "directional groups preserve partial overrides" {
    try expectMerge("p-4 px-2", "p-4 px-2");
    try expectMerge("px-2 p-4", "p-4");
    try expectMerge("rounded rounded-t-none", "rounded rounded-t-none");
    try expectMerge("rounded-t-none rounded", "rounded");
}

test "variants important and arbitrary properties keep independent scopes" {
    try expectMerge("hover:px-4 focus:px-2", "hover:px-4 focus:px-2");
    try expectMerge("p-4! p-2", "p-4! p-2");
    try expectMerge("p-4! p-2!", "p-2!");
    try expectMerge("p-2 [padding:1px]", "p-2 [padding:1px]");
}

test "font size and line-height use directional conflict semantics" {
    try expectMerge("text-sm leading-8", "text-sm leading-8");
    try expectMerge("leading-8 text-lg", "text-lg");
}

test "class groups carry the scope and property hashes mergeClasses compares" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeClassGroups(std.testing.allocator, test_theme, &.{ "px-2", "hover:px-4", "not-a-utility" }, &writer);
    const json = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"px-2\":[\""));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"not-a-utility\":[\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, json, "\",[]]}"));
    // px-2 owns padding-left + padding-right: scope, then two property hashes
    // (one comma after the scope, one between the properties).
    const px_start = std.mem.indexOf(u8, json, "\"px-2\":[").? + "\"px-2\":[".len;
    const px_end = std.mem.indexOfPos(u8, json, px_start, "]]").?;
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, json[px_start..px_end], ","));
}
