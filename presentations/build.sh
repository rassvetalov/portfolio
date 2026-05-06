#!/usr/bin/env bash
# Build presentation artifacts (HTML + PDF + PPTX) from Marp markdown sources.
#
# Strategy:
#   - HTML: ship Mermaid as client-side runtime (CDN-loaded). Diagrams render
#     in the browser at view-time. No headless Chromium needed at build time.
#   - PDF/PPTX: requires headless Chromium with system libs (libnspr4 etc).
#     If unavailable, only HTML build is run.
#
# Usage: ./build.sh [html|pdf|pptx|all]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"

if [ -x /tmp/node_modules/.bin/marp ]; then
    MARP="/tmp/node_modules/.bin/marp"
elif command -v marp >/dev/null 2>&1; then
    MARP="marp"
else
    MARP="npx --yes @marp-team/marp-cli@latest"
fi

mkdir -p "$BUILD_DIR"

format="${1:-html}"

build_one() {
    local src="$1"
    local fmt="$2"
    local base
    base=$(basename "$src" .marp.md)
    local out="$BUILD_DIR/${base}.${fmt}"
    
    echo "→ Building $base.$fmt"
    
    case "$fmt" in
        html)
            $MARP --html --no-stdin --config-file "$SCRIPT_DIR/marp.config.cjs" -o "$out" "$src"
            # Inject Mermaid client-side runtime
            node "$SCRIPT_DIR/postprocess-html.js" "$out"
            ;;
        pdf)
            $MARP --pdf --no-stdin --config-file "$SCRIPT_DIR/marp.config.cjs" -o "$out" "$src" || {
                echo "  ⚠ PDF build failed (Chromium missing? Install: sudo dnf install nss nspr)"
                return 1
            }
            ;;
        pptx)
            $MARP --pptx --no-stdin --config-file "$SCRIPT_DIR/marp.config.cjs" -o "$out" "$src" || {
                echo "  ⚠ PPTX build failed (same Chromium dependency as PDF)"
                return 1
            }
            ;;
    esac
    
    echo "  ✓ $out ($(du -h "$out" | cut -f1))"
}

for src in "$SCRIPT_DIR"/*.marp.md; do
    [ -f "$src" ] || continue
    
    case "$format" in
        html|pdf|pptx)
            build_one "$src" "$format" || true
            ;;
        all)
            build_one "$src" "html" || true
            build_one "$src" "pdf" || true
            build_one "$src" "pptx" || true
            ;;
        *)
            echo "Unknown format: $format. Use: html | pdf | pptx | all"
            exit 1
            ;;
    esac
done

echo ""
echo "✅ Done. Artifacts in: $BUILD_DIR"
ls -lh "$BUILD_DIR"/*.{html,pdf,pptx} 2>/dev/null || true
