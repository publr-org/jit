# Third-party notices

Publr JIT is distributed under the Apache License 2.0. Its compiler is an independent implementation: it does not contain or derive from Tailwind CSS compiler source code. It accepts many of the same class strings and aims to produce CSS with equivalent browser-visible behavior, although the generated CSS is not necessarily byte-for-byte identical.

The separately bundled compatibility preflight is the only material derived from the third-party project below. Its copyright and license notice must be retained with redistributions that include it.

## Tailwind CSS 4.2.2

- Project: Tailwind CSS
- Source: <https://github.com/tailwindlabs/tailwindcss/tree/v4.2.2>
- Copyright: Copyright (c) Tailwind Labs, Inc.
- License: MIT; the complete text is in [`LICENSES/Tailwind-CSS-MIT.txt`](LICENSES/Tailwind-CSS-MIT.txt).

`src/preflight.css` contains a modified version of Tailwind CSS Preflight so that equivalent class input starts from a compatible browser reset. No Tailwind CSS compiler code is included, linked, or required at build time or runtime.

Tailwind CSS and its contributors provide the covered material **as is**, without warranty; consult the bundled MIT license for the complete permission notice and warranty/liability disclaimer.
