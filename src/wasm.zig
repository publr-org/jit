//! Freestanding wasm entry — the Publr JIT as an in-browser CSS engine.
//!
//! No WASI: this exports a tiny linear-memory ABI (alloc/free/compile/outLen)
//! so a Web Worker can hand the compiler a class list and get CSS back, with
//! NO server, NO filesystem, NO stdio. It wraps the exact same `jit.compile()`
//! the native CLI uses — the CLI's argv/file/stdout plumbing (main.zig) is
//! deliberately NOT imported, which is what keeps this target freestanding-clean
//! (and small under ReleaseSmall).
//!
//! ABI (all lengths in bytes; pointers are wasm32 offsets into `memory`):
//!   alloc(len)        -> ptr   reserve a buffer for JS to write the class list
//!   compile(ptr,len)  -> ptr   compile the whitespace-separated classes at
//!                              ptr[0..len] with the default theme
//!   compileWithTheme(classes_ptr,classes_len,theme_ptr,theme_len) -> ptr
//!                              compile with a JSON Theme override merged onto
//!                              the default theme
//!   resolveClassesWithTheme(classes_ptr,classes_len,theme_ptr,theme_len) -> ptr
//!                              the class-conflict groups as JSON
//!                              ({class: [scope, [property…]]}) — what PublrJS
//!                              merges stacked class attributes with; a
//!                              BUILD-TIME call (Node), never shipped to pages
//!   outLen()          -> len   byte length of the last compile() result
//!   free(ptr,len)     -> void  release a buffer from alloc() or compile()
//!
//! JS flow: p = alloc(n); write bytes; c = compile(p,n); m = outLen();
//!          css = decode(memory[c..c+m]); free(c,m); free(p,n).
//!
//! Theme JSON has the same portable shape as the editor:
//!   {"tokens":[{"name":"color-brand","value":"#123456"}]}
//! The override is merged onto the embedded defaults for every compile.

const std = @import("std");
const jit = @import("jit.zig");
const default_theme: jit.Theme = @import("default-theme.zon");

// Freestanding wasm has no OS allocator; this is std's linear-memory page
// allocator (grows `memory` via @wasmMemoryGrow). Self-contained.
const gpa = std.heap.wasm_allocator;

// Byte length of the most recent successful compile() output. Read via
// outLen() immediately after compile(); reset to 0 on failure.
var out_len: usize = 0;

/// Reserve `len` bytes of wasm memory for JS to write into. Returns null (0)
/// if the allocation fails.
export fn alloc(len: usize) ?[*]u8 {
    const buf = gpa.alloc(u8, len) catch return null;
    return buf.ptr;
}

/// Release a buffer previously returned by `alloc` or `compile`.
export fn free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

/// Compile the whitespace-separated class list at `ptr[0..len]` to CSS.
/// Returns a pointer to freshly-allocated CSS bytes (owned by the caller —
/// `free(result, outLen())` when done), or null on failure (outLen() == 0).
export fn compile(ptr: [*]const u8, len: usize) ?[*]u8 {
    out_len = 0;
    const css = compileClasses(ptr[0..len], default_theme) catch return null;
    out_len = css.len;
    return css.ptr;
}

/// Compile a class manifest against a runtime JSON theme override. The parsed
/// theme and merge only live for this call; the returned CSS owns its bytes.
export fn compileWithTheme(
    classes_ptr: [*]const u8,
    classes_len: usize,
    theme_ptr: [*]const u8,
    theme_len: usize,
) ?[*]u8 {
    out_len = 0;
    const parsed = std.json.parseFromSlice(
        jit.Theme,
        gpa,
        theme_ptr[0..theme_len],
        .{ .ignore_unknown_fields = true },
    ) catch return null;
    defer parsed.deinit();

    const merged = jit.extendThemeRuntime(gpa, default_theme, parsed.value) catch return null;
    defer gpa.free(merged.tokens);

    const css = compileClasses(classes_ptr[0..classes_len], merged) catch return null;
    out_len = css.len;
    return css.ptr;
}

/// The class-conflict groups (JSON) of a manifest against a runtime JSON theme
/// override. Same tokenizing as `compile`; see `jit.writeClassGroups`.
export fn resolveClassesWithTheme(
    classes_ptr: [*]const u8,
    classes_len: usize,
    theme_ptr: [*]const u8,
    theme_len: usize,
) ?[*]u8 {
    out_len = 0;
    const parsed = std.json.parseFromSlice(
        jit.Theme,
        gpa,
        theme_ptr[0..theme_len],
        .{ .ignore_unknown_fields = true },
    ) catch return null;
    defer parsed.deinit();

    const merged = jit.extendThemeRuntime(gpa, default_theme, parsed.value) catch return null;
    defer gpa.free(merged.tokens);

    const json = resolveClasses(classes_ptr[0..classes_len], merged) catch return null;
    out_len = json.len;
    return json.ptr;
}

fn resolveClasses(input: []const u8, active_theme: jit.Theme) ![]u8 {
    var classes: std.ArrayList([]const u8) = .empty;
    defer classes.deinit(gpa);
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, input, " \t\n\r");
    while (it.next()) |class| {
        const gop = try seen.getOrPut(gpa, class);
        if (gop.found_existing) continue;
        try classes.append(gpa, class);
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try jit.writeClassGroups(gpa, active_theme, classes.items, &out.writer);
    return out.toOwnedSlice();
}

/// Byte length of the last successful `compile` result (0 after a failure).
export fn outLen() usize {
    return out_len;
}

/// Tokenize the class list (dedup, whitespace-split — the manifest shape the
/// native CLI reads from a file) and run it through the shared compiler.
fn compileClasses(input: []const u8, active_theme: jit.Theme) ![]u8 {
    var classes: std.ArrayList([]const u8) = .empty;
    defer classes.deinit(gpa);

    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();

    var it = std.mem.tokenizeAny(u8, input, " \t\r\n");
    while (it.next()) |c| {
        if (c.len == 0) continue;
        const gop = try seen.getOrPut(c);
        if (gop.found_existing) continue;
        try classes.append(gpa, c);
    }

    return jit.compile(gpa, active_theme, classes.items, .{ .minify = true });
}
