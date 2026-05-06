// Marp config: allow inline HTML so we can ship a client-side Mermaid runtime
// that renders <pre><code class="language-mermaid">...</code></pre> blocks at
// view-time (no headless Chromium needed at build-time).

module.exports = {
    html: true,           // permit raw HTML (incl. <script>) in markdown
    allowLocalFiles: true,
};
