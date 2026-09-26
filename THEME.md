# Theme schema

Publr's JIT takes its theme as a `theme.zon` value. The library API accepts a theme directly, while the CLI can load one with `--theme=<path>`.

## Schema

A theme is a flat list of `Token { name, value }` pairs. Each token corresponds 1:1 to a CSS custom property emitted in the JIT's `:root { ... }` block.

```zig
const Theme = struct {
    tokens: []const Token,
};

const Token = struct {
    name: []const u8,   // CSS-property name without the leading `--`
    value: []const u8,  // raw CSS value
};
```

ZON form:

```zig
.{
    .tokens = .{
        .{ .name = "font-sans", .value = "Switzer, system-ui, sans-serif" },
        .{ .name = "radius-4xl", .value = "2rem" },
        .{ .name = "color-brand-500", .value = "oklch(0.6 0.2 250)" },
    },
}
```

## Naming convention

Token names follow the JIT's CSS-custom-property convention (without the leading `--`):

| Namespace | Pattern | Examples |
|---|---|---|
| Single value | `<name>` | `spacing`, `radius` |
| Numbered scale | `<namespace>-<scale>-<step>` | `color-red-500`, `color-gray-950` |
| Named scale | `<namespace>-<name>` | `breakpoint-md`, `radius-lg`, `font-sans` |
| Modifier | `<base>--<modifier>` | `text-lg--line-height` |

The full default namespace list:

- `animate-*` — animation shorthands
- `aspect-*` — aspect ratios
- `blur-*` — blur amounts
- `breakpoint-*` — responsive breakpoints
- `color-*-<step>` — color scale (50/100/200/.../900/950)
- `container-*` — container query sizes
- `default-*` — defaults for built-in features
- `drop-shadow-*` — drop-shadow presets
- `ease-*` — animation easings
- `font-*` — font families and weights
- `inset-shadow-*`, `shadow-*` — shadow presets
- `leading-*` — line-heights
- `max-width-*` — max-width presets
- `perspective-*` — 3D perspective
- `radius`, `radius-*` — border-radius scale
- `spacing` — base spacing unit
- `text-*` — text size scale (with `--line-height` and `--letter-spacing` and `--font-weight` modifiers)
- `tracking-*` — letter-spacing presets

## Default theme

The JIT ships `default-theme.zon` (~419 tokens). Your `theme.zon` **extends** the default; you only specify what's different.

```zig
// jit/src/your-build.zig (illustrative)
const theme = @import("jit").theme;
const default_theme: theme.Theme = @import("default-theme.zon");
const user_theme: theme.Theme = @import("theme.zon");
const merged_theme = comptime theme.extendTheme(default_theme, user_theme);
```

`extendTheme` semantics:
- Tokens in `override` whose `name` matches a token in `base` **replace** the matching token (preserving `base`'s position in the order).
- Tokens in `override` not in `base` are **appended** in source order.

This is the single mode of theming. There is no "remove this default" mechanism — if you don't want a default, override it with whatever value you do want, or leave it (unused defaults emit harmlessly into `:root` and cost no runtime resolution).

## Authoring a `theme.zon`

You typically have just a handful of overrides. For example:

```zig
.{
    .tokens = .{
        .{ .name = "font-sans", .value = "Switzer, system-ui, sans-serif" },
    },
}
```

That's it. Everything else inherits from defaults.

For a more complex example with new tokens:

```zig
.{
    .tokens = .{
        // Override default font
        .{ .name = "font-sans", .value = "Inter, system-ui, sans-serif" },

        // Add a custom color scale
        .{ .name = "color-brand-50", .value = "oklch(0.97 0.02 250)" },
        .{ .name = "color-brand-500", .value = "oklch(0.6 0.2 250)" },
        .{ .name = "color-brand-900", .value = "oklch(0.25 0.1 250)" },

        // Add a custom radius
        .{ .name = "radius-blob", .value = "37% 63% 70% 30% / 30% 30% 70% 70%" },
    },
}
```

## Importing an existing theme

If you have an existing CSS file with `@theme { ... }`, run:

```bash
jit theme-from-css ./theme.css > theme.zon
```

The converter produces an **override-only** `theme.zon` — only the tokens you explicitly defined, not the full default. (See `task-03-theme-from-css.md`.)

## Output

At JIT compile time, the merged theme emits as the first thing in your CSS output:

```css
:root {
  --font-sans: Switzer, system-ui, sans-serif;
  --color-red-50: oklch(97.1% 0.013 17.38);
  --color-red-100: oklch(93.6% 0.032 17.717);
  /* ... ~419 entries ... */
  --radius-4xl: 2rem;
}

@layer utilities {
  /* generated utility rules */
}
```

Tokens are emitted in the order they appear in the merged theme (defaults first in their original order, user-appended tokens last). Classes reference tokens via `var(--name)`, so you can also use `[var(--my-token)]` arbitrary references.

## Limitations

- **No per-namespace removal.** The converter does not interpret `--*: initial;` as namespace removal. If you want to replace a default, override it with a value.
- **No `@theme inline`, `@theme default` modes.** Single override-extend mode only. The converter (task-03) flags these modifier words with a warning and treats them as bare `@theme {}`.
- **Nested `@keyframes` inside `@theme {}` not yet supported.** Define `@keyframes` separately in your CSS, outside `@theme`. The converter skips nested at-rules with a warning.

## Browser runtime

The browser engine accepts the same portable theme through
`compileWithTheme(classes, themeJson)`. It merges that document onto the
embedded defaults before compiling, so live theme editing and the native CLI
use the same resolver.
