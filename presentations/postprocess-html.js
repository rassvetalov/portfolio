#!/usr/bin/env node
// Post-process Marp HTML output: inject Mermaid client-side runtime
// (CDN-loaded) so Mermaid code blocks render in browser at view-time.
// No Chromium needed at build time.
//
// Usage: node postprocess-html.js <input.html> [output.html]

const fs = require('node:fs');
const path = require('node:path');

if (process.argv.length < 3) {
    console.error('Usage: postprocess-html.js <input.html> [output.html]');
    process.exit(1);
}

const inputFile = process.argv[2];
const outputFile = process.argv[3] || inputFile;

let html = fs.readFileSync(inputFile, 'utf-8');

// Mermaid runtime: load from CDN, scan all .language-mermaid code blocks,
// replace them with <div class="mermaid"> elements, then run mermaid.
const mermaidScript = `
<script type="module">
import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';

mermaid.initialize({
    startOnLoad: false,
    theme: 'default',
    themeVariables: {
        fontFamily: 'Inter, sans-serif',
        fontSize: '18px',
    },
    flowchart: { useMaxWidth: true, htmlLabels: true, curve: 'basis' },
    sequence: { useMaxWidth: true },
});

// Convert all Marp-wrapped code blocks to mermaid divs and render.
async function renderMermaidBlocks() {
    const blocks = document.querySelectorAll('pre code.language-mermaid');
    for (let i = 0; i < blocks.length; i++) {
        const code = blocks[i];
        const pre = code.closest('pre');
        const wrapper = pre.parentElement;
        const graphDef = code.textContent;
        
        const div = document.createElement('div');
        div.className = 'mermaid';
        div.id = 'mermaid-' + i;
        div.style.textAlign = 'center';
        div.textContent = graphDef;
        
        // Replace the entire <pre> wrapper with mermaid div
        if (wrapper && wrapper !== document.body) {
            wrapper.replaceChild(div, pre);
        } else {
            pre.replaceWith(div);
        }
    }
    
    if (blocks.length > 0) {
        await mermaid.run({ querySelector: '.mermaid' });
    }
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', renderMermaidBlocks);
} else {
    renderMermaidBlocks();
}
</script>

<style>
.mermaid {
    background: white;
    padding: 12px;
    border-radius: 8px;
    max-width: 100%;
    overflow: visible;
}
.mermaid svg {
    max-width: 100% !important;
    max-height: 60vh !important;
    height: auto !important;
}
pre code.language-mermaid {
    display: none;  /* hide raw mermaid source until JS swaps it */
}
</style>
`;

// Inject right before </body>
if (html.includes('</body>')) {
    html = html.replace('</body>', `${mermaidScript}\n</body>`);
} else {
    html += mermaidScript;
}

fs.writeFileSync(outputFile, html);
console.error(`[postprocess] Injected Mermaid runtime into ${path.basename(outputFile)}`);
