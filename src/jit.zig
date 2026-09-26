/// Public API surface for the Publr class JIT.
///
/// Single import path for downstream consumers (CMS, design-system, demos).
///
///   const jit = @import("jit.zig");
///   const default_theme: jit.Theme = @import("default-theme.zon");
///   const my_theme: jit.Theme = @import("theme.zon");
///   const merged = comptime jit.extendTheme(default_theme, my_theme);
///
///   const css = try jit.compile(allocator, merged, &.{ "flex", "p-4", "hover:bg-red-500" });
///   defer allocator.free(css);
///
/// Core coverage:
///   - Theme parsing + extension + CSS variable emission.
///   - Candidate parser (variants, modifiers, arbitrary values, important).
///   - Static + functional utility kinds (subset; see SUPPORTED.md).
///   - Static + functional + compound + arbitrary variant kinds.
///   - Deterministic, cascade-aware class sorting.
///   - Modern CSS emission (`:root` + `@layer utilities`).
///
/// Excluded (per epic's "Not in scope"):
///   - lightningcss-equivalent post-processing.
///   - `@apply`, `@import`, `@source`, `@utility`, `@variant`, `@custom-variant`.
///   - Plugin API.
const compile_mod = @import("compile.zig");
const theme_mod = @import("theme.zig");
const sort_mod = @import("sort.zig");
const class_merge_mod = @import("class_merge.zig");

pub const Theme = theme_mod.Theme;
/// The built-in token set; consumers layer their `theme.zon` over it.
pub const default_theme: Theme = @import("default-theme.zon");
pub const Token = theme_mod.Token;
pub const extendTheme = theme_mod.extendTheme;
pub const extendThemeRuntime = theme_mod.extendThemeRuntime;
pub const lookup = theme_mod.lookup;
pub const emitCssVariables = theme_mod.emitCssVariables;

pub const compile = compile_mod.compile;
pub const CompileError = compile_mod.CompileError;
pub const unsupportedFeatureMessage = compile_mod.unsupportedFeatureMessage;

pub const sortClasses = sort_mod.sortClasses;
pub const SortError = sort_mod.SortError;
pub const mergeClasses = class_merge_mod.mergeClasses;
pub const writeClassGroups = class_merge_mod.writeClassGroups;
