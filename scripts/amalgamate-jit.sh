#!/bin/sh
# Generate the single-file Publr JIT module distributed to consumers.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SRC="$ROOT/src"
OUT="$ROOT/publr_jit.zig"
MODE=${1:-write}

case "$MODE" in
    write|--check) ;;
    *)
        echo "usage: $0 [--check]" >&2
        exit 2
        ;;
esac

TMP=$(mktemp "${TMPDIR:-/tmp}/publr-jit.XXXXXX")
trap 'rm -f "$TMP"' EXIT HUP INT TERM

# Match the ZSX distribution process: tests stay in canonical src/ files and
# are omitted from the generated consumer artifact.
strip_tests() {
    awk '
    /^\/\/ =+$/ { next }
    /^\/\/ Tests$/ { next }
    /^test "/ { skip = 1; depth = 0 }
    skip {
        for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            if (c == "{") depth++
            if (c == "}") depth--
        }
        if (depth <= 0) { skip = 0; depth = 0 }
        next
    }
    { print }
    ' | cat -s
}

emit_plain_namespace() {
    name=$1
    file=$2
    echo "pub const $name = struct {"
    sed \
        -e 's|const candidate = @import("candidate\.zig");|const candidate = amalgam.candidate_mod;|' \
        -e 's|const theme = @import("theme\.zig");|const theme = amalgam.theme_mod;|' \
        -e 's|const theme_mod = @import("theme\.zig");|const theme_mod = amalgam.theme_mod;|' \
        -e 's|const utilities = @import("utilities\.zig");|const utilities = amalgam.utilities_mod;|' \
        -e 's|const variants = @import("variants\.zig");|const variants = amalgam.variants_mod;|' \
        -e 's|const sort = @import("sort\.zig");|const sort = amalgam.sort_mod;|' \
        "$file" | strip_tests
    echo "};"
    echo
}

{
    echo "// SPDX-License-Identifier: Apache-2.0"
    echo "// Publr JIT Amalgamation — generated from jit/src/*.zig"
    echo "// Do not edit directly. Regenerate: ./scripts/amalgamate-jit.sh"
    echo "// The third-party compatibility preflight is distributed separately."
    echo
    echo "const amalgam = @This();"
    echo

    emit_plain_namespace candidate_mod "$SRC/candidate.zig"
    emit_plain_namespace theme_mod "$SRC/theme.zig"
    emit_plain_namespace utilities_mod "$SRC/utilities.zig"
    emit_plain_namespace variants_mod "$SRC/variants.zig"
    emit_plain_namespace sort_mod "$SRC/sort.zig"
    emit_plain_namespace class_merge_mod "$SRC/class_merge.zig"
    emit_plain_namespace compile_mod "$SRC/compile.zig"
    emit_plain_namespace theme_from_css_mod "$SRC/theme_from_css.zig"

    echo "const embedded_default_theme: theme_mod.Theme ="
    awk '
        !converted && /\.tokens = \.\{/ {
            sub(/\.tokens = \.\{/, ".tokens = \\&.{")
            converted = 1
        }
        { print }
    ' "$SRC/default-theme.zon" | sed '$s/}$/};/'
    echo

    echo "pub const api = struct {"
    echo "    pub const Theme = amalgam.theme_mod.Theme;"
    echo "    pub const Token = amalgam.theme_mod.Token;"
    echo "    pub const extendTheme = amalgam.theme_mod.extendTheme;"
    echo "    pub const extendThemeRuntime = amalgam.theme_mod.extendThemeRuntime;"
    echo "    pub const lookup = amalgam.theme_mod.lookup;"
    echo "    pub const emitCssVariables = amalgam.theme_mod.emitCssVariables;"
    echo "    pub const compile = amalgam.compile_mod.compile;"
    echo "    pub const CompileError = amalgam.compile_mod.CompileError;"
    echo "    pub const unsupportedFeatureMessage = amalgam.compile_mod.unsupportedFeatureMessage;"
    echo "    pub const sortClasses = amalgam.sort_mod.sortClasses;"
    echo "    pub const SortError = amalgam.sort_mod.SortError;"
    echo "    pub const mergeClasses = amalgam.class_merge_mod.mergeClasses;"
    echo "    pub const writeClassGroups = amalgam.class_merge_mod.writeClassGroups;"
    echo "    pub const default_theme: Theme = amalgam.embedded_default_theme;"
    echo "};"
    echo

    echo "pub const cli = struct {"
    sed \
        -e 's|const theme_from_css = @import("theme_from_css\.zig");|const theme_from_css = amalgam.theme_from_css_mod;|' \
        -e 's|const jit = @import("jit\.zig");|const jit = amalgam.api;|' \
        -e 's|const default_theme: jit\.Theme = @import("default-theme\.zon");|const default_theme: jit.Theme = amalgam.embedded_default_theme;|' \
        "$SRC/main.zig"
    echo "};"
    echo
    echo "pub fn main() !void {"
    echo "    return cli.main();"
    echo "}"
} > "$TMP"

if [ "$MODE" = "--check" ]; then
    if [ ! -f "$OUT" ] || ! cmp -s "$TMP" "$OUT"; then
        echo "publr_jit.zig is stale; run ./scripts/amalgamate-jit.sh" >&2
        exit 1
    fi
    echo "publr_jit.zig is up to date"
    exit 0
fi

mv "$TMP" "$OUT"
trap - EXIT HUP INT TERM
LINES=$(wc -l < "$OUT" | tr -d ' ')
echo "Amalgamated -> $OUT ($LINES lines)"
