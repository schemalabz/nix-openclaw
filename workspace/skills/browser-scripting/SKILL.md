---
name: browser-scripting
description: Access the web programmatically — READ a page's content as clean markdown, or OPERATE a real browser (navigate, click, screenshot, intercept network). Use when reading a JS-heavy page, verifying browser behaviour, or scripting a browser.
---

# Web access: read vs operate

Pick by intent:

- **Read a page's content** (article, docs, product info) → `page-read <url>` — cheap, clean markdown; renders JS only when needed. Add `--json` for `{markdown, title, tier}`. Replaces fetcher.
- **Operate / observe** (click, fill, screenshot, intercept network) → write an ESM script and run it with `playwright-run script.mjs`.

Neither defeats bot-managed sites: Cloudflare/DataDome challenge pages ("Just a moment…", "Verify you are human") come back regardless of tool or IP — that's the site blocking automation, not a bug. Don't loop retrying; note it and move on.

## playwright-run

`playwright-run script.mjs [args...]` — node + a matched nix Playwright + Chromium, sanitized env so the browser launches even inside a project `nix develop`.

Import via the env var (ESM ignores NODE_PATH):

    const pw = await import(process.env.PLAYWRIGHT);
    const { chromium } = pw.default ?? pw;
    const browser = await chromium.launch();       // { headless: false } to watch
    const page = await browser.newPage();
    page.on('request', (r) => { if (r.url().includes('_rsc=')) console.log('RSC', r.url()); });
    await page.goto('https://example.com', { waitUntil: 'domcontentloaded' });
    console.log(await page.title());
    await browser.close();

Notes:

- Scripts are `.mjs`; top-level await is fine. The browser is nix-provided — don't `npx playwright install`.
- **Dev servers compile routes on first hit** — after navigate/click, wait for `networkidle` (or the "Compiling…" overlay to clear) before screenshotting, or you capture a half-rendered page.
- Screenshot loop for feature work: a small `shot.mjs` that navigates then `page.screenshot({ path, fullPage: true })`, then `Read` the PNG.
- Selectors: prefer `href`/role locators; some "cards" are `div`s with onClick, not anchors.
- Live/map pages never reach `networkidle`; use `domcontentloaded` + explicit waits.
