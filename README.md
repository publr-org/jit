# Publr JIT

A bespoke Zig class-to-CSS compiler. It is **100% Zig** and compiles natively and for `wasm32-wasi`.

## What it is

```zig
const jit = @import("publr_jit.zig").api;

const css = try jit.compile(allocator, jit.default_theme, &.{
    "flex",
    "p-4",
    "hover:bg-red-500",
    "md:grid",
    "@container",
});
defer allocator.free(css);
```

Returns a CSS document with `:root { --token: value; ... }` (only the tokens actually referenced by the output — theme tree-shaking) followed by `@layer utilities { ... }`.

## What it does

- Parses class strings with variants, modifiers, arbitrary values, and `!important`.
- Resolves each class against a comptime utility/variant table.
- Emits modern CSS — `@layer`, `color-mix()` for opacity, `@container` for container queries, logical properties (`border-inline-start-radius` etc.).
- Tree-shakes theme tokens so `:root` only contains what's used.
- Sorts classes by cascade-affecting rules (variant precedence, `!important` last).

## What it doesn't do

- Parse user CSS (`@apply`, `@import`, `@source`, `@utility`, `@variant`, `@custom-variant` are out of scope).
- Scan files for class strings — class collection belongs to the ZSX/.publr transpilers, which produce manifests.
- Post-process CSS (no minification, vendor-prefixing, nesting flattening — pipe through lightningcss/postcss downstream if needed).
- Track another compiler's versions; the test suite and supported-surface document define this compiler's contract.

That said, **runtime theme overrides ARE supported** — `jit.compile()` takes the theme at runtime, and the CLI accepts `--theme=<path>`. The JIT itself is theme-agnostic; consumers pass their own theme.zon at the JIT's runtime (which is the consumer's build time). Earlier docs that called this "out of scope" were wrong; see the Theme model section below.

See [`SUPPORTED.md`](SUPPORTED.md) for the full surface, [`UNSUPPORTED.md`](UNSUPPORTED.md) for the intentional exclusions and migration messages.

## Architecture

| File | Role |
|------|------|
| `publr_jit.zig` | Generated single-file distribution: public API, CLI, and embedded default theme. |
| `scripts/amalgamate-jit.sh` | Regenerates `publr_jit.zig` from canonical source and supports `--check`. |
| `src/jit.zig` | Public API surface (re-exports `compile`, `Theme`, `extendTheme`, `unsupportedFeatureMessage`, ...) |
| `src/compile.zig` | Pipeline: parse → resolve → variant-wrap → sort → emit. Tree-shakes theme tokens. |
| `src/candidate.zig` | Class string parser (variants, values, modifiers, important). |
| `src/utilities.zig` | Comptime table of utility kinds + handlers. ~120 test blocks. |
| `src/variants.zig` | Comptime table of variant kinds + compound dispatch (`group-`, `peer-`, `not-`, `has-`, `in-`, container queries, arbitrary at-rules). |
| `src/theme.zig` | `Theme` schema, `extendTheme()` comptime merge, `lookup()`, `:root` emission. |
| `src/sort.zig` | Cascade-aware sort. |
| `src/theme_from_css.zig` | One-shot converter: CSS `@theme {}` block → `theme.zon`. |
| `src/main.zig` | CLI: reads class manifest, emits CSS to stdout. Demo flow. |
| `default-theme.zon` | 419-token default theme (colors, spacing, breakpoints, fonts, radius, shadows, ease, durations, container sizes, text sizes). |

## Theme model

**Theme-agnostic.** `jit.compile(allocator, theme: Theme, classes)` takes the theme as a runtime parameter. The CLI accepts `--theme=<path>` to load a `theme.zon` and merge it onto the embedded default. Two merge functions are exposed:

```zig
// Comptime path (consumer bakes theme into their binary)
const my_theme: jit.Theme = @import("theme.zon");
const merged = comptime jit.extendTheme(jit.default_theme, my_theme);

// Runtime path (CLI / WASM / dynamic loading)
const my_theme = try std.zon.parse.fromSlice(jit.Theme, allocator, zon_bytes, null, .{});
const merged = try jit.extendThemeRuntime(allocator, default_theme, my_theme);
```

The CLI does the runtime version automatically:

```bash
./zig-out/bin/jit --theme=cms/theme.zon classes.txt > admin.css
./zig-out/bin/jit classes.txt > admin.css   # uses embedded default-theme.zon
```

**One CSS bundle per theme** still holds — output is fully determined at the consumer's build time. The JIT being theme-agnostic just means one JIT binary serves any consumer, instead of one JIT binary per theme.

## Using

```bash
# Build
zig build                  # produces zig-out/bin/jit

# Regenerate or verify the single-file distribution
./scripts/amalgamate-jit.sh
./scripts/amalgamate-jit.sh --check

# Run on a class manifest
./zig-out/bin/jit <classes.txt>            # → CSS to stdout
./zig-out/bin/jit --prepend preflight.css <classes.txt>  # prepend preflight

# One-shot @theme conversion (migration tool)
./zig-out/bin/jit theme-from-css <input.css>   # → theme.zon to stdout
```

## Testing

```bash
zig build test         # ~620 unit tests across all modules
zig build test-amalgamation  # verifies + tests publr_jit.zig
zig build test-wasm    # compile-only check for wasm32-wasi
```

Each utility/variant kind ships with a `test "..."` block asserting the exact CSS bytes. **The tests are the spec.**

## Contract and versioning

The supported classes and emitted CSS are defined by [`SUPPORTED.md`](SUPPORTED.md) and the test suite. Changes to that contract are made and reviewed in this repository.

## License

Publr JIT is licensed under the [Apache License 2.0](LICENSE). Its bundled compatibility preflight contains modified third-party material under a compatible license; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the corresponding file in [`LICENSES/`](LICENSES/).
