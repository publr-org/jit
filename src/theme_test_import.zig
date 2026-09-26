// Verifies default-theme.zon imports cleanly into the Theme struct
// and exercises lookup + emit on it. This file is a build-time test only.

const std = @import("std");
const theme = @import("theme.zig");

const default_theme: theme.Theme = @import("default-theme.zon");

test "default-theme.zon imports as Theme" {
    // The checked-in default contains more than 400 tokens.
    try std.testing.expect(default_theme.tokens.len > 0);
    try std.testing.expect(default_theme.tokens.len >= 400);
}

test "default-theme.zon: known tokens lookup" {
    try std.testing.expect(theme.lookup(default_theme, "spacing") != null);
    try std.testing.expect(theme.lookup(default_theme, "color-red-500") != null);
    try std.testing.expect(theme.lookup(default_theme, "breakpoint-md") != null);
    try std.testing.expect(theme.lookup(default_theme, "font-sans") != null);
    try std.testing.expect(theme.lookup(default_theme, "color-gray-950") != null);
    try std.testing.expect(theme.lookup(default_theme, "radius-md") != null);

    // Must be absent: tokens not in the checked-in defaults.
    try std.testing.expectEqual(@as(?[]const u8, null), theme.lookup(default_theme, "color-publr-purple"));
    try std.testing.expectEqual(@as(?[]const u8, null), theme.lookup(default_theme, "color-brand-600"));
}

test "default-theme.zon emits as :root block" {
    const css = try theme.emitCssVariables(std.testing.allocator, default_theme);
    defer std.testing.allocator.free(css);

    // Sanity: starts with `:root {`, contains a known token, ends with `}`.
    try std.testing.expect(std.mem.startsWith(u8, css, ":root {\n"));
    try std.testing.expect(std.mem.indexOf(u8, css, "--spacing: 0.25rem;") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "--color-red-500:") != null);
    try std.testing.expect(std.mem.endsWith(u8, css, "}\n"));
}

test "extendTheme: /site overrides apply correctly to defaults" {
    // Representative site @theme overrides.
    // Note: --radius-4xl is already in the defaults (2rem); /site's
    // override is a no-op for value but still goes through the merge path.
    const site_overrides = theme.Theme{
        .tokens = &.{
            .{ .name = "font-sans", .value = "Switzer, system-ui, sans-serif" },
            .{ .name = "radius-4xl", .value = "2rem" },
            // Add one truly-new token so we exercise the append path.
            .{ .name = "color-brand-600", .value = "oklch(0.6 0.2 250)" },
        },
    };

    const merged = comptime theme.extendTheme(default_theme, site_overrides);

    // font-sans is overridden
    try std.testing.expectEqualStrings(
        "Switzer, system-ui, sans-serif",
        theme.lookup(merged, "font-sans").?,
    );
    // radius-4xl override (same value, just reaffirms the merge path)
    try std.testing.expectEqualStrings("2rem", theme.lookup(merged, "radius-4xl").?);
    // truly-new token appended
    try std.testing.expectEqualStrings("oklch(0.6 0.2 250)", theme.lookup(merged, "color-brand-600").?);
    // unrelated default token survives
    try std.testing.expect(theme.lookup(merged, "color-red-500") != null);
    // length is base + 1 (font-sans + radius-4xl are overrides; only color-brand-600 is new)
    try std.testing.expectEqual(default_theme.tokens.len + 1, merged.tokens.len);
}
