# Publr JIT — Unsupported Surface

> The intentional exclusions. Anything listed here is **out of scope by design**, not a "not yet" — adding it would conflict with locked architectural decisions. Anything *not* listed here and *not* in [`SUPPORTED.md`](SUPPORTED.md) is a coverage gap and should be reported.

## CSS directives

These return `error.UnsupportedFeature` (when invoked through a code path that parses user CSS) and have a migration message available via `jit.unsupportedFeatureMessage(name)`:

### `@apply`

> "Publr JIT does not support @apply. Migration: rewrite the rule to apply utility classes directly in HTML, or define the equivalent CSS by hand."

**Why:** `@apply` requires AST-walking user CSS to expand utility names into their declarations. The JIT operates on a *class list*, not a CSS document; there's no input-CSS path to apply against. The architecturally correct way to compose utilities in Publr is at the markup layer (ZSX templates), not in user CSS.

### `@import`

> "Publr JIT does not support @import. Migration: inline the imported CSS, or compose stylesheets at the build/serve layer outside the JIT."

**Why:** No `loadStylesheet` infrastructure. Users assemble CSS externally — typically the build pipeline prepends `preflight.css` and any user CSS to the JIT's output.

### `@source`

> "Publr JIT does not support @source. Migration: class strings are collected from ZSX/.publr templates at build time — no file scanner is invoked. Remove the directive; the JIT will pick up classes via the transpiler manifest."

**Why:** No file scanners. Class collection belongs to the transpilers; the JIT receives a manifest and compiles it.

### `@utility`

> "Publr JIT does not support @utility. Migration: add the utility to jit/src/utilities.zig (comptime table) and rebuild — runtime utility registration is intentionally out of scope."

**Why:** Utility kinds are a comptime table for performance + WASM bundle size. Runtime registration would require a parsing layer for utility definitions and a hashmap dispatch — both unnecessary if the table is rebuilt with the JIT.

### `@variant`

> "Publr JIT does not support @variant. Migration: add the variant to jit/src/variants.zig (comptime table) and rebuild — runtime variant registration is intentionally out of scope."

**Why:** Same as `@utility`. Variants are a comptime table.

### `@custom-variant`

> "Publr JIT does not support @custom-variant. Migration: add the variant to jit/src/variants.zig (comptime table) and rebuild — runtime variant registration is intentionally out of scope."

**Why:** Same as `@utility` / `@variant`.

## Other intentional exclusions

### lightningcss-equivalent post-processing
- Nesting flattening for older browsers
- Vendor prefixing (`-webkit-*`, `-moz-*`)
- Adjacent-rule merging across compile passes
- Browser-target feature transforms
- Minification

**Why:** Generic CSS post-processing is outside the class compiler. Pipe JIT output through a post-processor downstream if needed.

### Plugin API
- Third-party plugin loading
- `addUtilities`, `addComponents`, `addVariants` runtime APIs
- Plugin theme extension at runtime

**Why:** Publr ships no runtime plugins. The JIT uses compile-time class and variant tables for one project's needs.

### Source maps
**Why:** Deferred. The JIT's output is small enough that source-class lookup is rarely needed. Reconsider when consumers ask.

### Scanner / file walking
**Why:** Class strings come from the ZSX/.publr transpilers via a manifest, not by scanning files.

### (Removed 2026-05-03 — runtime theme overrides ARE supported)

The earlier "no runtime theme override" exclusion was based on a confused mental model — it conflated JIT-build-time with consumer-build-time. The JIT is theme-agnostic at the tool level; consumers pass theme.zon at the JIT's runtime (which is the consumer's build time). Multi-tenant deployments and live CMS theme editing are both possible. See `jit.extendThemeRuntime` and the `--theme=<path>` CLI flag.

### Byte-equality tests against external compilers
**Why:** The JIT has its own class contract. The spec is the test suite, not another compiler's output bytes.

## What's *not* on either list

Anything that's neither in `SUPPORTED.md` nor in the lists above is a **coverage gap** — a kind that should plausibly work but doesn't. Report these by adding a `test "..."` block in the appropriate `jit/src/*.zig` file with the desired output, then make it pass. The JIT silently emits no rule for unknown classes (no error), so these gaps surface as "the class did nothing" in consumer output.

## How errors surface

For directive-class exclusions (the `@apply`/`@import`/etc. set above), `jit.compile()` itself doesn't currently raise `error.UnsupportedFeature` — its API takes pre-tokenized class strings, not user CSS, so there's no entry point where these directives appear. The error variant + messages exist for **future user-CSS entry points** (loaders, plugin hosts) so they error consistently. Code calling `jit.compile()` today won't see this error in normal operation.

For the other intentional exclusions (lightningcss, plugins, scanners, etc.), there's no error at all — the feature simply doesn't exist in the public API.
