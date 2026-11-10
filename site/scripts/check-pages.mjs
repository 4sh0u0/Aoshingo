// SPDX-License-Identifier: Apache-2.0
//
// Checks every page of site/public in Chromium:
//   - axe-core (WCAG 2.2 A/AA and best practices) in light, dark, increased-contrast and
//     forced-colours modes
//   - no horizontal scrolling at 320 CSS px wide (WCAG 1.4.10 Reflow)
//   - every internal link and #fragment resolves
//   - no request leaves the site (no third-party fonts, scripts or trackers)
//
// Set PLAYWRIGHT_CHROMIUM_EXECUTABLE to use an already installed Chromium.

import AxeBuilder from "@axe-core/playwright";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { chromium } from "playwright";
import { BASE_PATH, PUBLIC_DIR, startServer } from "./serve.mjs";

const PUBLISHED_ORIGIN = "https://4sh0u0.github.io";
const PAGES = ["", "support/", "privacy/", "this-page-does-not-exist/"];
const MODES = [
  { name: "light", options: { colorScheme: "light" } },
  { name: "dark", options: { colorScheme: "dark" } },
  { name: "more-contrast", options: { colorScheme: "light", contrast: "more" } },
  { name: "dark-more-contrast", options: { colorScheme: "dark", contrast: "more" } },
  // axe computes contrast from the author colours, which forced-colours mode replaces with the
  // system palette, so color-contrast is skipped there; everything else still runs.
  { name: "forced-colors", options: { forcedColors: "active" }, disableRules: ["color-contrast"] },
];
const AXE_TAGS = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa", "best-practice"];

const server = await startServer();
const browser = await chromium.launch({
  executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined,
});
const failures = [];
const fail = (message) => {
  failures.push(message);
  console.error(`✗ ${message}`);
};

/** Serves requests for the published URL (used by 404.html) from the local files. */
async function routeRequests(context, external) {
  await context.route("**/*", async (route) => {
    const url = new URL(route.request().url());
    if (url.origin === server.origin) return route.continue();
    if (url.origin === PUBLISHED_ORIGIN && url.pathname.startsWith(BASE_PATH)) {
      const response = await context.request.get(`${server.origin}${url.pathname}${url.search}`);
      return route.fulfill({ response });
    }
    external.add(url.href);
    return route.abort();
  });
}

const pageIds = new Map();

async function idsOf(pathname) {
  if (!pageIds.has(pathname)) {
    let relative = pathname.slice(BASE_PATH.length);
    if (relative === "" || relative.endsWith("/")) relative += "index.html";
    const html = await readFile(path.join(PUBLIC_DIR, relative), "utf8").catch(() => null);
    const ids = html === null ? null : new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]));
    pageIds.set(pathname, ids);
  }
  return pageIds.get(pathname);
}

try {
  for (const mode of MODES) {
    const context = await browser.newContext({ ...mode.options, locale: "ja-JP" });
    const external = new Set();
    await routeRequests(context, external);
    const page = await context.newPage();

    for (const pagePath of PAGES) {
      const label = `/${pagePath} [${mode.name}]`;
      const response = await page.goto(`${server.url}${pagePath}`, { waitUntil: "load" });
      const expected = pagePath.startsWith("this-page-does-not-exist") ? 404 : 200;
      if (response?.status() !== expected) fail(`${label}: HTTP ${response?.status()}, expected ${expected}`);

      const stylesheetLoaded = await page.evaluate(() =>
        [...document.styleSheets].some((sheet) => sheet.href?.endsWith("/assets/style.css")),
      );
      if (!stylesheetLoaded) fail(`${label}: style.css did not load`);

      const results = await new AxeBuilder({ page })
        .withTags(AXE_TAGS)
        .disableRules(mode.disableRules ?? [])
        .analyze();
      for (const violation of results.violations) {
        const targets = violation.nodes.map((node) => node.target.join(" ")).slice(0, 5).join(", ");
        fail(`${label}: axe ${violation.id} (${violation.impact}): ${violation.help} → ${targets}`);
      }

      if (mode.name === "light") {
        // Reflow at 320 CSS px, the width of a 1280 px window zoomed to 400 %.
        await page.setViewportSize({ width: 320, height: 640 });
        const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
        if (overflow > 0) fail(`${label}: scrolls horizontally by ${overflow}px at 320px wide`);
        const clipped = await page.evaluate(() =>
          [...document.querySelectorAll(".table-wrap, pre")]
            .filter((element) => element.scrollWidth > element.clientWidth)
            .map((element) => element.className || element.tagName),
        );
        for (const name of clipped) fail(`${label}: ${name} scrolls horizontally at 320px wide`);
        await page.setViewportSize({ width: 1280, height: 800 });

        const links = await page.evaluate(() =>
          [...document.querySelectorAll("a[href]")].map((a) => ({
            href: a.href,
            samePage: a.getAttribute("href").startsWith("#"),
            resolves: a.getAttribute("href").startsWith("#")
              ? document.getElementById(decodeURIComponent(a.hash.slice(1))) !== null
              : true,
          })),
        );
        for (const { href, samePage, resolves } of links) {
          if (samePage) {
            if (!resolves) fail(`${label}: link ${href} has no target on the page`);
            continue;
          }
          const target = new URL(href);
          const local =
            target.origin === server.origin ||
            (target.origin === PUBLISHED_ORIGIN && target.pathname.startsWith(BASE_PATH));
          if (!local) continue;
          const localURL = `${server.origin}${target.pathname}`;
          const status = (await page.request.get(localURL, { maxRedirects: 0 })).status();
          if (status !== 200) fail(`${label}: link ${href} returned HTTP ${status}`);
          if (target.hash) {
            const ids = await idsOf(target.pathname);
            if (!ids?.has(decodeURIComponent(target.hash.slice(1)))) fail(`${label}: link ${href} has no target`);
          }
        }
      }
      console.log(`✓ ${label}: ${results.passes.length} axe rules passed`);
    }

    for (const href of external) fail(`[${mode.name}] external request: ${href}`);
    await context.close();
  }
} finally {
  await browser.close();
  await server.close();
}

if (failures.length > 0) {
  console.error(`\n${failures.length} problem(s) found.`);
  process.exit(1);
}
console.log("\nAll pages passed.");
