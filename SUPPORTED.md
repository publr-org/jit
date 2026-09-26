# Publr JIT — Supported Surface

> **The contract.** Every utility kind, variant kind, and modifier listed here has at least one passing `test "..."` block in `jit/src/{utilities,variants,compile}.zig`. Anything not on this list either compiles to no output (silent skip) or returns `error.UnsupportedFeature` with a migration message — see `UNSUPPORTED.md`.

## Contract

The compiler implementation is independently written, bespoke Zig (`jit/src/*.zig`). This document and the test suite define the supported class contract. The separately bundled compatibility preflight is inventoried in `THIRD_PARTY_NOTICES.md`.

## API

```zig
const jit = @import("publr_jit.zig").api;
const my_theme: jit.Theme = @import("theme.zon");
const merged = comptime jit.extendTheme(jit.default_theme, my_theme);

const css = try jit.compile(allocator, merged, &.{ "flex", "p-4", "hover:bg-red-500" });
defer allocator.free(css);
```

`jit.compile()` returns `:root { --token: value; ... } @layer utilities { ... }`. Theme tree-shaking emits only tokens actually referenced by the utility output.

Public exports (`@import("publr_jit.zig").api`): `Theme`, `Token`, `default_theme`, `extendTheme`, `lookup`, `emitCssVariables`, `compile`, `sortClasses`, `CompileError`, `SortError`, `unsupportedFeatureMessage`.

## Utility kinds

### Layout & display
- `block`, `inline`, `inline-block`, `flex`, `inline-flex`, `grid`, `inline-grid`, `hidden`
- `static`, `relative`, `absolute`, `fixed`, `sticky`
- `flex-row`, `flex-col`, `flex-wrap`, `flex-nowrap`
- `isolate`, `transform-gpu`, `transform-none`

### Justify / align
- `justify-{start,center,between,end}`
- `items-{start,center,end,baseline}`
- `self-center`

### Sizing
- **Spacing dispatch** — `w-N`, `h-N`, `min-w-N`, `min-h-N`, `max-w-N`, `max-h-N`. Numeric values use the spacing scale; `auto`, `full` (100%), `px` (1px), `min`/`max`/`fit` (min/max/fit-content), `svw`/`lvw`/`dvw` keywords; arbitrary `w-[var(--my-w)]`.
- `size-N` — sets both width + height.
- Viewport-units statics: `w-screen`, `h-screen`, `min-w-screen`, `min-h-screen`, `max-w-screen`, `max-h-screen`, `h-svh`, `h-lvh`, `h-dvh`.
- Aspect-ratio: `aspect-square`, `aspect-video`, `aspect-auto`, `aspect-W/H` (functional).
- Fractions on sizing/inset: `w-1/2`, `h-2/3`, `inset-1/4`, `-mt-1/2`, multi-digit (`w-11/12`).

### Spacing — padding / margin / gap
- **Padding** — `p`/`pt`/`pr`/`pb`/`pl`/`px`/`py`/`ps`/`pe` × N (and arbitrary).
- **Margin** — `m`/`mt`/`mr`/`mb`/`ml`/`mx`/`my`/`ms`/`me` × N. Negative variants (`-m-N`, `-mx-2`, etc.).
- **Gap** — `gap-N`, `gap-x-N`, `gap-y-N`.
- **Space-between** (selector-modifying) — `space-x-N`, `space-y-N` emit `> :not(:last-child)` rules. Plus `space-x-reverse`/`space-y-reverse` markers.
- **Scroll-padding/margin** — `scroll-p`/`pt`/`pr`/`pb`/`pl`/`px`/`py` × N, same for `scroll-m*`.
- Fractional spacing (half-step scale): `0.5`, `1.5`, `2.5`, `3.5`, ...

### Position / inset
- `inset-N`, `inset-x-N`, `inset-y-N` (and negative).
- `top-N`, `right-N`, `bottom-N`, `left-N`, `start-N`, `end-N` (and negative).
- Arbitrary forms (`inset-[10px]`).

### Grid
- `col-span-N`, `row-span-N` (numeric or arbitrary `col-span-[5]`).
- `col-start-N`, `col-end-N`, `row-start-N`, `row-end-N`.
- `grid-cols-{N|subgrid|none|arbitrary}`, `grid-rows-{N|subgrid|none|arbitrary}`.
- Statics: `col-auto`, `col-span-full`, `col-start-auto`, `col-end-auto`, `row-auto`, `row-span-full`, `row-start-auto`, `row-end-auto`.

### Z-index / order
- `z-N`, `-z-N`.
- `order-N`, `-order-N`, `order-first`, `order-last`, `order-none`.

### Typography
- `text-{size}` — theme-driven (`--text-{size}`); emits `font-size` + optional `line-height`.
- `text-{size}/{N|[arb]}` — modifier overrides line-height (e.g. `text-2xl/8` → `line-height: calc(var(--spacing) * 8)`).
- `font-{family}` — theme-driven (`--font-{key}`).
- `text-{left,center,right,justify}` — text-align.
- `text-{balance,pretty,wrap,nowrap}` — text-wrap.
- `text-{clip,ellipsis}` — text-overflow.
- `truncate` — overflow:hidden + text-overflow:ellipsis + white-space:nowrap.
- `uppercase`, `lowercase`, `capitalize`, `normal-case`.
- `italic`, `not-italic`.
- `underline`, `overline`, `line-through`, `no-underline`.
- `tracking-{tighter,tight,normal,wide,wider}` — letter-spacing.
- `antialiased`, `subpixel-antialiased`.

### Color
- **Color-property utilities** — `bg-`, `text-`, `border-`, `ring-`, `decoration-`, `outline-`, `accent-`, `caret-`, `fill-`, `stroke-`. Each accepts:
  - Theme color (`bg-red-500` via `--color-red-500` lookup)
  - Special keywords (`bg-transparent`, `bg-current`, `bg-inherit`)
  - Arbitrary (`bg-[#abc]`, `bg-[var(--my-color)]`)
  - Opacity modifier (`bg-red-500/50` → `color-mix(in srgb, var(--color-red-500) 50%, transparent)`)
- **Color palette** — 22 named families × 11 shades, plus `black`/`white`. See `default-theme.zon`.
- **Shadow color** — `shadow-{color}` sets `--tw-shadow-color`; pairs with `shadow-{size}`.

### Border
- **Width** — bare `border` (1px), `border-N`, `border-{t,r,b,l,x,y,s,e}` (1px + side), `border-{side}-N`, `border-x/y-N`, arbitrary `border-[3.5px]`.
- **Style** — `border-{solid,dashed,dotted,double,hidden,none}`.
- **Color** — via the color path (`border-red-500` etc.), including physical
  and logical side forms (`border-{t,r,b,l,s,e}-{color}`).
- **Radius** — bare `rounded` (`var(--radius)`), `rounded-none` (0), `rounded-full` (`calc(infinity * 1px)`), `rounded-{key}` (theme `radius-{key}`), arbitrary `rounded-[7px]`. Side variants: `rounded-{t,r,b,l}-{key}` (2 longhands), `rounded-{tl,tr,br,bl}-{key}` (1 longhand). Logical: `rounded-{s,e}-{key}`, `rounded-{ss,se,es,ee}-{key}`.

### Shadow
- `shadow` (bare), `shadow-none`, `shadow-{key}` (theme `--shadow-{key}`), `shadow-[arb]`.
- `shadow-{color}` / `shadow-{color}/{op}` — sets `--tw-shadow-color`.

### Outline
- Bare `outline` (1px solid).
- `outline-N` (width), `outline-[arb]`.
- `outline-{none,hidden,solid,dashed,dotted,double}` styles.
- `outline-{color}` via color path.
- `outline-offset-N`, `outline-offset-[-N]`.

### Background gradients
- Direction: `bg-linear-to-{t,tr,r,br,b,bl,l,tl}`, `bg-linear-{angle}` (e.g. `bg-linear-45`), `bg-linear-[arb]`.
- Conic: bare `bg-conic`, `bg-conic-{angle}`, `bg-conic-[arb]`.
- Radial: bare `bg-radial`, `bg-radial-[arb]`.
- Stops: `from-{color}`, `via-{color}`, `to-{color}` (theme color or arbitrary). Position forms: `from-{percent}`, `to-{percent}`, etc. Opacity modifier: `from-blue-500/50`.

### Transition / animation
- Bare `transition`; specific: `transition-{all,colors,opacity,shadow,transform,none}`.
- `duration-N` (ms), `duration-[arb]`, `duration-initial`, `duration-{theme-key}`.
- `delay-N` (ms), `delay-[arb]`, `delay-initial`, `delay-{theme-key}`.
- Easing: `ease-{linear,in,out,in-out,initial}` statics; `ease-{theme-key}`; `ease-[cubic-bezier(...)]`.

### Transform
- Translate longhands: `translate-x-N`, `translate-y-N`, `translate-z-N` (and negative).

### Misc
- **Cursor** — 35 variants: `auto`, `default`, `pointer`, `wait`, `text`, `move`, `help`, `not-allowed`, `none`, `context-menu`, `progress`, `cell`, `crosshair`, `vertical-text`, `alias`, `copy`, `no-drop`, `grab`, `grabbing`, `all-scroll`, `col-resize`, `row-resize`, 8 directional resizes, `nesw-resize`/`nwse-resize`, `zoom-in`, `zoom-out`.
- **User-select** — `select-{none,text,all,auto}`.
- **Object-fit** — `object-{contain,cover,fill,none,scale-down}`.
- **Object-position** — `object-{top,right,bottom,left,center,top-right,top-left,bottom-right,bottom-left}`.
- **Pointer-events** — `pointer-events-{auto,none}`.
- **Resize** — `resize`, `resize-x`, `resize-y`, `resize-none`.
- **Overflow** — `overflow-{auto,hidden,clip,visible,scroll}`, `overflow-x-*`, `overflow-y-*` (full sets).
- **Overflow shorthand** — `truncate` (3-decl shortcut).
- **Marker classes** — `peer`, `group`, `space-x-reverse`, `space-y-reverse` resolve to empty rules (used by compound variants on sibling/ancestor elements).
- **Filter** — `blur-{key}`, `blur-[arb]`, `blur-none`.
- **Mask** — `mask-[arb]`, `mask-(--var)` passthrough.
- **Ring** — `ring-inset` static; `ring-{color}` via color path.
- **Aspect ratio** — `aspect-W/H`, `aspect-[arb]`.
- **Arbitrary properties** — `[--my-prop:42]`, `[color:red]/50` (opacity modifier on color-shaped properties applies `color-mix(in oklab, ...)`).

### `!important` syntax
- Trailing: `underline!`, `size-12!`.
- Leading (legacy): `!underline`, `!flex`.
- On arbitrary properties: `[color:red]!`.

## Variant kinds

### Pseudo-classes
- `hover`, `focus`, `focus-visible`, `focus-within`, `active`, `visited`, `target`, `disabled`, `enabled`, `checked`, `indeterminate`, `default`, `required`, `valid`, `invalid`, `placeholder-shown`, `read-only`, `open`.

### Structural
- `first`, `last`, `only`, `odd`, `even`, `first-of-type`, `last-of-type`, `only-of-type`, `empty`.

### Pseudo-elements
- `before`, `after`, `placeholder`, `selection`, `marker`, `file`, `backdrop`.
- **Selector ordering** — pseudo-classes always emit before the trailing pseudo-element (`hover:before:flex` and `before:hover:flex` both produce `:hover::before`).

### Color scheme & media
- `dark`, `light` — `prefers-color-scheme` media queries.
- `motion-reduce`, `motion-safe` — `prefers-reduced-motion`.
- `print`, `forced-colors`.

### Breakpoints (theme-driven)
- `sm:`, `md:`, `lg:`, `xl:`, `2xl:` etc. — uses the
  `--breakpoint-{key}` literal value. Custom keys may be hyphenated
  (`gallery-canvas:` → `--breakpoint-gallery-canvas`).
- `max-{key}:` — `(max-width: ...)` form, including hyphenated custom keys
  (`max-gallery-canvas:`).

### Functional variants
- `data-[k=v]:`, `data-[k]:` — attribute selectors.
- `aria-[k=v]:` — aria attribute.
- `supports-[(...)]:` — `@supports` at-rule.

### Compound variants
- `group-*` — `.group <inner>` ancestor pattern. `group/foo` named-group modifier.
- `peer-*` — same with `.peer ~`.
- **`not-*`** — wraps inner in `:not(...)` (e.g. `not-hover:` → `:not(:hover)`).
- **`has-*`** — wraps inner in `:has(...)` (e.g. `has-[input:focus]:` → `:has(:is(input:focus))`).
- **`in-*`** — `:where(<inner>) <selector>` (matches "any ancestor satisfying inner").

### Container queries
- Bare `@container:` — `@container { ... }` (responds to nearest container).
- `@<key>:` — theme-driven `@container (width >= var(--container-<key>))`.
- `@max-<key>:` — `(width < ...)` form.
- `@[400px]:` — arbitrary condition.
- `@max-[500px]:` — arbitrary max condition.

### Arbitrary variants
- Selector form: `[&_p]:`, `[&[data-foo]]:`, `[input:focus]:` (parser wraps non-relative in `&:is(...)` so the class is included).
- Relative combinators: `[>img]:`, `[+img]:`, `[~img]:`.
- At-rule form: `[@media(width>=123px)]:`, `[@supports(display:grid)]:`. Allow-list of safe at-rule names: `media`, `supports`, `container`, `starting-style`.

### Stacking
- All variants stack in source order: `md:hover:flex` produces `@media (min-width: ...)` wrapping `.flex:hover`.
- Pseudo-elements always come last in the selector regardless of source order.

## Modifiers

- **Opacity on color utilities** — `/N` (named percent: `bg-red-500/50` → 50%) or `/[arb]` (arbitrary: `bg-red-500/[27%]`, `bg-red-500/(--my-op)`). Wraps in `color-mix(in srgb, ..., transparent)`.
- **Opacity on arbitrary color properties** — `[color:red]/50` → `color-mix(in oklab, red 50%, transparent)`. Detected via `isColorProperty()` allow-list.
- **Line-height on text size** — `text-2xl/8` overrides theme default line-height with `calc(var(--spacing) * 8)` (or `var(--leading-8)` if defined). Arbitrary: `text-2xl/[1.5]`.
- **Fractions on sizing** — `w-1/2` → `calc(1/2 * 100%)`. Works with negative variants (`-mt-1/2`) and multi-digit (`w-11/12`).
- **Position on gradient stops** — `from-50%`, `to-[25%]`.

## Theme

- **Theme-agnostic at the JIT level.** `jit.compile()` takes the theme as a runtime parameter. The CLI accepts `--theme=<path>` to load a `theme.zon` and merge it onto the embedded default. The consumer's build process is "runtime" from the JIT's perspective, so the theme is fully resolved at consumer-build-time — output is still predictable and one-bundle-per-theme.
- Default theme (`default-theme.zon`) ships 419 tokens covering colors, spacing, breakpoints, fonts, radius, shadows, ease, durations, container sizes, text sizes (with line-heights), keyframes. Used as fallback when no `--theme=` is supplied.
- Two merge functions:
  - `jit.extendTheme(comptime base, comptime override)` — comptime merge, for callers baking theme into their own binary.
  - `jit.extendThemeRuntime(allocator, base, override)` — runtime merge for the CLI / WASM path. Same semantics.
- Token namespaces consumed by the JIT: `color-*`, `spacing`, `spacing-*`, `breakpoint-*`, `container-*`, `font-*`, `text-*`, `text-*--line-height`, `radius-*`, `radius`, `shadow-*`, `shadow`, `blur-*`, `ease-*`, `duration-*`, `leading-*`, `default-transition-duration`, `default-transition-timing-function`.
- Theme tree-shaking: only tokens actually referenced by the emitted utility rules (transitively) appear in the `:root { }` block. A 7-class input that touches 3 tokens emits 3 tokens, not 419.

## Contract versioning

This contract is maintained in this repository. It does not automatically track any external compiler or framework.

## Verification

- Each kind has at least one passing `test "..."` block in `jit/src/{utilities,variants,compile,candidate,sort,theme}.zig`.
- `zig build test` runs all unit tests (~620 across the JIT source tree).
- `zig build test-wasm` confirms the JIT compiles for `wasm32-wasi`.
- See [`UNSUPPORTED.md`](UNSUPPORTED.md) for what is *intentionally* not supported.

## Coverage additions (2026-05-03)

The exhaustive-enumeration sweep (jit-coverage-closure task-08) added the following utility/variant ports. See `.claude/plans/jit-coverage-closure/PORT-LIST.md` for the full snapshot.

### New static utilities (~300 entries)
- **Display**: full table family (`table-cell`, `table-row`, `table-caption`, …), `flow-root`, `contents`, `list-item`, `field-sizing-{content,fixed}`
- **Visibility / box**: `visible`, `invisible`, `collapse`, `box-{border,content}`, `box-decoration-{slice,clone}`, `isolation-auto`
- **Float / clear**: `float-{start,end,right,left,none}`, `clear-{start,end,right,left,both,none}`
- **Flex / grid**: `flex-{row,col,wrap}-reverse`, `place-content-*` (10), `place-items-*` (7), `place-self-*` (7), `align-content` `content-*` (11), `items-{end-safe,center-safe,baseline-last,stretch,normal}`, `justify-{normal,around,evenly,center-safe,end-safe,baseline,stretch}`, `justify-items-*` (7), `justify-self-*` (7), `self-{auto,start,end,end-safe,center-safe,stretch,baseline,baseline-last}`, `grid-flow-*` (5), `auto-cols-{auto,min,max,fr}`, `auto-rows-{...}`
- **Background**: `bg-{auto,cover,contain}`, `bg-{fixed,local,scroll}`, 9 position statics, 6 repeat statics, `bg-none`, 4 `bg-clip-*`, 3 `bg-origin-*`, 16 `bg-blend-*`, 18 `mix-blend-*`, `via-none`
- **Typography**: `text-{start,end}`, `align-{baseline,top,middle,bottom,sub,super,text-top,text-bottom}`, 5 `decoration-{style}`, `decoration-{auto,from-font}`, `hyphens-{none,manual,auto}`, 6 `whitespace-*`, `break-{normal,all,keep}`, `wrap-{anywhere,break-word,normal}`, `list-{inside,outside}`, `normal-nums`, `content-none`
- **Border / table**: `border-{collapse,separate}`, `table-{auto,fixed}`, `caption-{top,bottom}`
- **Effects**: `shadow-{initial,inherit}`, `inset-shadow-initial`, `drop-shadow-none`, `text-shadow-initial`, `filter-none`, `backdrop-filter-none`, bare-defaults `grayscale`/`invert`/`sepia` (100%), `blur` (8px), backdrop counterparts
- **Transform**: `transform-{cpu,flat,3d,content,border,fill,stroke,view}`, `translate-{none,3d}`, `scale-{none,3d}`, `rotate-none`, `backface-{visible,hidden}`
- **Transition / forms**: `transition-{discrete,normal}`, `duration-initial`, `appearance-{none,auto}`, 6 `scheme-*`
- **Interactivity**: 10 `touch-action`, 12 scroll/snap, 4 `will-change-*`, 9 overscroll, 20 break-before/inside/after
- **Accessibility / contain**: `forced-color-adjust-{none,auto}`, 8 `contain-*`
- **Mask family** (~57 entries): composite/mode/type/size/position/repeat/clip/origin/radial-shape/radial-size/radial-position
- **Color**: `accent-auto`, `fill-none`, `stroke-none`
- **Sizing**: `h-lh`/`min-h-lh`/`max-h-lh`, full logical `inline-*` and `block-*` static keyword set (full/min/max/fit/screen/svw/lvw/dvw/svh/lvh/dvh/auto/lh)
- **Font-variant-numeric**: `ordinal slashed-zero lining-nums oldstyle-nums proportional-nums tabular-nums diagonal-fractions stacked-fractions`

### New functional utilities
- **Logical sides** (added to spacing dispatch): `inset-{s,e,bs,be}-{spacing}`, `mbs/mbe-{spacing}`, `pbs/pbe-{spacing}`, `scroll-{ms,me,mbs,mbe,ps,pe,pbs,pbe}-{spacing}`
- **Sizing logical**: `inline-{N|spacing}`, `block-{N|spacing}`, `min/max-inline-{N}`, `min/max-block-{N}`
- **Grid**: `col-{N}` / `-col-{N}` (grid-column integer), `row-{N}` / `-row-{N}`, `auto-cols-{auto/min/max/fr/arb/theme}`, `auto-rows-{...}`
- **Flex**: `flex-{N}` (integer), `flex-{W/H}` (fraction), `flex-[arb]`, `shrink-{N}`, `grow-{N}`, `basis-{spacing}`
- **Border-spacing**: `border-spacing-{N}`, `border-spacing-x-{N}`, `border-spacing-y-{N}` composed via `--tw-border-spacing-x/y`
- **Object/cursor/will-change/contain**: `object-{theme/arb}`, `cursor-{theme/arb}`, `will-change-[arb]`, `contain-[arb]`
- **Aspect**: `aspect-{theme}` (`--aspect-{name}` lookup) in addition to fraction/numeric
- **Typography functional**: `line-clamp-{N|none|theme|arb}` (4-decl webkit-box), `indent-{spacing}`, `tracking-{theme/arb}` with negative, `leading-{N|theme|none|arb}`, `underline-offset-{N|auto|arb}` with negative, `decoration-{thickness}` (numeric → `Npx`), `list-{theme/arb}`, `list-image-{theme/arb}`, `content-{theme/arb}` (sets `--tw-content` + `content`)
- **Columns**: `columns-{N|auto|theme|arb}`
- **Filter / backdrop-filter**: `brightness-{N}`, `contrast-{N}`, `saturate-{N}`, `hue-rotate-{±N}`, `grayscale-{N}`, `invert-{N}`, `sepia-{N}`, `blur-[arb]`, plus all the `backdrop-*` mirrors. **Note**: each emits a direct `filter:`/`backdrop-filter:` declaration; multiple filters on the same element overwrite. Composed-chain via `--tw-*` vars is a future PR (Phase C in the port-list).
- **Drop-shadow / animations**: `drop-shadow-{theme/arb}` simple emission, `animate-{name|none|arb}` with `--animate-{name}` theme lookup (falls back to `var(--animate-{name})`)
- **Ring extensions**: `ring-offset-{N|color}`, `inset-ring-{N|color}`
- **Transform composition**: `translate-{N}` (sets both axes + composed `translate:`), `translate-x/y/z-{N}` (sets per-axis var + composed), `scale-{N}` and `scale-x/y/z-{N}` analogous, `rotate-{±N}` (single property), `rotate-{x,y,z}-{N}` (3D `transform: rotateX(…)`), `skew-{x,y}-{N}` composed via `--tw-skew-{axis}`, `origin-{name|theme|arb}`, `perspective-origin-{...}`, `perspective-{N|none|theme|arb}`
