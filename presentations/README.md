# Conference Presentations

Marp-based slide decks for technical conferences (KubeCon, PromCon, FinOps X).

## Decks

| File | Topic | Duration | Audience |
|---|---|---|---|
| [`01-victoria-metrics-multiaz-architecture.marp.md`](./01-victoria-metrics-multiaz-architecture.marp.md) | Multi-AZ VM architecture without RF=2 tax | 25 min | Platform/SRE (500+ ppl) |
| [`02-scraper-locality-optimization.marp.md`](./02-scraper-locality-optimization.marp.md) | When to defer scraper-locality optimization | 20 min | FinOps/Platform (200-300 ppl) |

## Building

### Quick start (HTML, no dependencies beyond Node.js)

```bash
./build.sh html
open build/01-victoria-metrics-multiaz-architecture.html
```

HTML output uses **client-side Mermaid runtime** (loaded from CDN at view-time).
No headless Chromium needed at build-time.

### Full build (HTML + PDF + PPTX)

```bash
./build.sh all
```

PDF/PPTX requires headless Chromium with system libs. On Fedora/Amazon Linux:

```bash
sudo dnf install -y nss nspr atk at-spi2-atk gtk3 cups-libs libdrm libxkbcommon \
  alsa-lib pango cairo libXcomposite libXdamage libXrandr
```

On Debian/Ubuntu:

```bash
sudo apt install -y libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 \
  libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 \
  libgbm1 libpango-1.0-0 libcairo2 libasound2
```

## File structure

```
presentations/
├── 01-victoria-metrics-multiaz-architecture.marp.md   # Source markdown (Marp)
├── 02-scraper-locality-optimization.marp.md           # Source markdown (Marp)
├── 01-victoria-metrics-multiaz-architecture-ru.md     # Original Russian draft (ASCII art)
├── 02-scraper-locality-optimization-ru.md             # Original Russian draft (ASCII art)
├── marp.config.cjs                                    # Marp CLI config (allows inline HTML)
├── build.sh                                           # Build orchestrator
├── postprocess-html.js                                # Injects Mermaid runtime into HTML
└── build/                                             # Generated artifacts (gitignored)
    ├── *.html                                         # Self-contained HTML decks
    ├── *.pdf                                          # PDF (if Chromium available)
    └── *.pptx                                         # PowerPoint (if Chromium available)
```

## Speaker notes

Each `.marp.md` file contains:
- **YAML frontmatter** — theme, paginate, custom CSS
- **`---` separators** — slide breaks
- **Mermaid code blocks** — rendered client-side in HTML, server-side in PDF
- **Markdown tables** — rendered as styled tables
- **Custom CSS classes** — `.columns`, `.big-number`, `.savings`, `.cost`, `.key-insight`, `.roi-box`

## Theme

Both decks use the **gaia** theme with custom Inter font and per-deck color accents:
- Deck 1 (Multi-AZ): Material Blue `#1976d2`
- Deck 2 (Scraper Locality): Material Orange `#ff6f00`

## Live preview

Use VSCode with the [Marp for VS Code extension](https://marketplace.visualstudio.com/items?itemName=marp-team.marp-vscode):

1. Open any `.marp.md` file
2. `Ctrl+Shift+V` for live preview
3. Mermaid renders inline

## References

- [Marp documentation](https://marp.app/)
- [Mermaid live editor](https://mermaid.live/)
- [Companion case studies](../case-studies/)
