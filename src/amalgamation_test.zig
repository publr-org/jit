const std = @import("std");
const jit = @import("publr_jit").api;

test "amalgamated public API compiles classes" {
    const css = try jit.compile(
        std.testing.allocator,
        jit.default_theme,
        &.{ "flex", "p-4", "hover:bg-red-500" },
        .{ .minify = true },
    );
    defer std.testing.allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, ".flex") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".p-4") != null);
}
