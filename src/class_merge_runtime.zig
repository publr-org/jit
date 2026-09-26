//! Allocation-convenience wrapper used by generated ZSX views.

const std = @import("std");
const class_merge = @import("class_merge.zig");
const theme = @import("theme.zig");
const default_theme: theme.Theme = @import("default-theme.zon");

pub fn mergeClassesRt(parts: []const []const u8) []const u8 {
    return class_merge.mergeClasses(std.heap.page_allocator, default_theme, parts) catch
        concatFallback(parts);
}

fn concatFallback(parts: []const []const u8) []const u8 {
    var length: usize = 0;
    for (parts) |part| length += part.len;
    const output = std.heap.page_allocator.alloc(u8, length) catch return "";
    var offset: usize = 0;
    for (parts) |part| {
        @memcpy(output[offset .. offset + part.len], part);
        offset += part.len;
    }
    return output;
}
