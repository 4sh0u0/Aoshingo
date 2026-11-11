// SPDX-License-Identifier: Apache-2.0
//
// Checks every page of site/public in Chromium:
//   - axe-core (WCAG 2.2 A/AA and best practices) in light, dark, increased-contrast and
//     forced-colours modes
//   - no horizontal scrolling at 320 CSS px wide (WCAG 1.4.10 Reflow)
//   - every internal link and #fragment resolves, every resource the page loads exists, and every
//     link to a file in this repository (github.com/4sh0u0/Aoshingo/blob/main/...) points to a file
//     that exists in the checkout
//   - requests that leave the site go only to the GitHub and Cloudflare infrastructure listed in
//     ALLOWED_EXTERNAL_HOSTS (no other fonts, scripts, analytics or widgets), and Turnstile is not
//     loaded until the 「メールアドレスを表示」 button is pressed
//   - the 「メールアドレスを表示」 button (assets/contact.js) with stand-ins for Turnstile and the
//     contact Worker: keyboard use, focus, status messages, errors and axe in the revealed state
//
// Set PLAYWRIGHT_CHROMIUM_EXECUTABLE to use an already installed Chromium.

import AxeBuilder from "@axe-core/playwright";
import { readFile, stat } from "node:fs/promises";
import path from "node:path";
import { chromium } from "playwright";
import { BASE_PATH, PUBLIC_DIR, startServer } from "./serve.mjs";

const PUBLISHED_ORIGIN = "https://4sh0u0.github.io";
const PAGES = ["", "guide/", "support/", "about/", "privacy/", "this-page-does-not-exist/"];
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

// Hosts outside the site that pages may load from: only this project's own GitHub and Cloudflare
// infrastructure. Exact host names only: github.io, workers.dev and the like are shared by everyone,
// so a suffix match would let any third party's page or Worker through. Before a page starts loading
// from a new host, say in "11. このウェブサイト" of the privacy policy what it is used for and what it
// receives. Requests to these hosts are blocked during the check, so it stays offline.
const ALLOWED_EXTERNAL_HOSTS = new Set([
  "github.com",
  "4sh0u0.github.io",
  "challenges.cloudflare.com", // Turnstile, only after the 「メールアドレスを表示」 button is pressed
  "aoshingo-contact.harus-account.workers.dev", // site/contact-worker
]);

const isAllowedExternal = (hostname) => ALLOWED_EXTERNAL_HOSTS.has(hostname);

// Links to files in this repository on GitHub are checked against the checkout. Files that another
// pull request adds can be listed here until it is merged. Once they exist, the check prints a warning
// (a GitHub Actions annotation) so that the entry is removed, but does not fail: merging the other pull
// request first must not stop this site from being published.
const REPOSITORY_BLOB_PREFIX = "https://github.com/4sh0u0/Aoshingo/blob/main/";
const REPOSITORY_ROOT = path.resolve(PUBLIC_DIR, "../..");
const PENDING_REPOSITORY_FILES = new Set([
  // e.g. "docs/new-guide.md", // added by PR #N
]);

// The 「メールアドレスを表示」 button. The check replaces the real Turnstile script and the Worker with
// stand-ins, so it needs no keys and no network.
const TURNSTILE_HOST = "challenges.cloudflare.com";
const CONTACT_PAGES = ["support/", "privacy/"];
const TEST_SITEKEY = "1x00000000000000000000AA";
const TEST_ENDPOINT = "https://aoshingo-contact.example.workers.dev/v1/email";
const TEST_TOKEN = "XXXX.DUMMY.TOKEN.XXXX";
const TEST_EMAIL = "contact@example.com";
const STUB_TURNSTILE = `(() => {
  const onload = new URL(document.currentScript.src).searchParams.get("onload");
  const widgets = new Map();
  let next = 0;
  window.__turnstileRenders = [];
  window.turnstile = {
    render(container, options) {
      const id = String(++next);
      const frame = document.createElement("p");
      frame.textContent = "Turnstile（テスト用の代わり）";
      container.append(frame);
      widgets.set(id, frame);
      window.__turnstileRenders.push({ sitekey: options.sitekey, action: options.action, language: options.language });
      setTimeout(() => options.callback(${JSON.stringify(TEST_TOKEN)}), 50);
      return id;
    },
    remove(id) {
      widgets.get(id)?.remove();
      widgets.delete(id);
    },
  };
  window[onload]();
})();`;

const server = await startServer();
const browser = await chromium.launch({
  executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined,
});
const failures = [];
const fail = (message) => {
  failures.push(message);
  console.error(`✗ ${message}`);
};

/**
 * Serves requests for the published URL (used by 404.html) from the local files, and blocks and
 * records every other request that leaves the local server.
 */
async function routeRequests(context, external, handle = null) {
  await context.route("**/*", async (route) => {
    const url = new URL(route.request().url());
    if (handle && (await handle(route, url))) return;
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
const repositoryLinks = new Map();
const pendingWarned = new Set();

async function checkRepositoryLink(label, href) {
  const file = decodeURIComponent(new URL(href).pathname.slice(new URL(REPOSITORY_BLOB_PREFIX).pathname.length));
  if (!repositoryLinks.has(file)) {
    const exists = await stat(path.join(REPOSITORY_ROOT, file)).then(
      () => true,
      () => false,
    );
    repositoryLinks.set(file, exists);
  }
  const exists = repositoryLinks.get(file);
  if (exists && PENDING_REPOSITORY_FILES.has(file)) {
    if (!pendingWarned.has(file)) {
      pendingWarned.add(file);
      console.log(`::warning::${file} now exists; remove it from PENDING_REPOSITORY_FILES in site/scripts/check-pages.mjs`);
    }
  } else if (!exists && !PENDING_REPOSITORY_FILES.has(file)) {
    fail(`${label}: link ${href} points to a file that is not in the repository`);
  }
}

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

    let label = "";
    const isSite = (url) =>
      url.origin === server.origin || (url.origin === PUBLISHED_ORIGIN && url.pathname.startsWith(BASE_PATH));
    page.on("response", (response) => {
      if (response.request().isNavigationRequest() || response.status() < 400) return;
      if (isSite(new URL(response.url()))) fail(`${label}: ${response.url()} returned HTTP ${response.status()}`);
    });
    page.on("requestfailed", (request) => {
      if (isSite(new URL(request.url()))) fail(`${label}: ${request.url()} failed (${request.failure()?.errorText})`);
    });

    for (const pagePath of PAGES) {
      label = `/${pagePath} [${mode.name}]`;
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
          if (href.startsWith(REPOSITORY_BLOB_PREFIX)) {
            await checkRepositoryLink(label, href);
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

    for (const href of external) {
      if (new URL(href).hostname === TURNSTILE_HOST) {
        fail(`[${mode.name}] Turnstile was loaded before the button was pressed: ${href}`);
      } else if (isAllowedExternal(new URL(href).hostname)) {
        console.log(`  [${mode.name}] external request to allowed infrastructure (blocked in the check): ${href}`);
      } else {
        fail(`[${mode.name}] external request to a host not in ALLOWED_EXTERNAL_HOSTS: ${href}`);
      }
    }
    await context.close();
  }
  await checkContactButton();
} finally {
  await browser.close();
  await server.close();
}

/** Presses the 「メールアドレスを表示」 button on each page that has it, with stand-ins. */
async function checkContactButton() {
  const source = await readFile(path.join(PUBLIC_DIR, "assets/contact.js"), "utf8");
  const configPattern = /sitekey: "[^"]*",(\s*\/\/[^\n]*\n\s*)endpoint: "[^"]*",/;
  if (!configPattern.test(source)) {
    fail("assets/contact.js: CONFIG not found (the check rewrites sitekey and endpoint)");
    return;
  }
  const testSource = source.replace(configPattern, `sitekey: "${TEST_SITEKEY}",$1endpoint: "${TEST_ENDPOINT}",`);

  for (const mode of MODES.filter(({ name }) => name === "light" || name === "dark")) {
    const context = await browser.newContext({ ...mode.options, locale: "ja-JP" });
    const external = new Set();
    const state = { turnstileLoads: 0, blockTurnstile: false, workerStatus: 200, workerRequests: [] };
    await routeRequests(context, external, async (route, url) => {
      const request = route.request();
      if (url.origin === server.origin && url.pathname === `${BASE_PATH}assets/contact.js`) {
        await route.fulfill({ contentType: "text/javascript; charset=utf-8", body: testSource });
        return true;
      }
      if (url.hostname === TURNSTILE_HOST && url.pathname === "/turnstile/v0/api.js") {
        state.turnstileLoads += 1;
        if (state.blockTurnstile) await route.abort();
        else await route.fulfill({ contentType: "text/javascript", body: STUB_TURNSTILE });
        return true;
      }
      if (url.href === TEST_ENDPOINT) {
        state.workerRequests.push({ method: request.method(), body: request.postData(), origin: request.headers().origin });
        const status = state.workerStatus;
        await route.fulfill({
          status,
          contentType: "application/json",
          headers: { "access-control-allow-origin": server.origin },
          body: JSON.stringify(status === 200 ? { email: TEST_EMAIL } : { error: "test" }),
        });
        return true;
      }
      return false;
    });
    const page = await context.newPage();

    for (const pagePath of CONTACT_PAGES) {
      const label = `/${pagePath} [${mode.name}] contact button`;
      const failuresBefore = failures.length;
      Object.assign(state, { turnstileLoads: 0, blockTurnstile: false, workerStatus: 200, workerRequests: [] });
      const statusText = () => page.locator("[data-contact-status]").textContent();
      const waitForStatus = async (pattern) => {
        try {
          await page.waitForFunction(
            (source) => new RegExp(source).test(document.querySelector("[data-contact-status]")?.textContent ?? ""),
            pattern.source,
            { timeout: 5000 },
          );
          return true;
        } catch {
          fail(`${label}: status message did not match ${pattern} (it was "${await statusText()}")`);
          return false;
        }
      };
      const button = page.locator("[data-contact-button]");
      const buttonHasFocus = () =>
        page.evaluate(() => document.activeElement === document.querySelector("[data-contact-button]"));
      const pressButton = async () => {
        await button.focus();
        await page.keyboard.press("Enter");
      };

      await page.goto(`${server.url}${pagePath}`, { waitUntil: "load" });
      if (!(await button.isVisible())) {
        fail(`${label}: the button is not shown`);
        continue;
      }
      if (state.turnstileLoads !== 0) fail(`${label}: Turnstile was loaded before the button was pressed`);

      // 1. The Worker refuses (rate limit): the message is announced and the button can be used again.
      state.workerStatus = 429;
      await pressButton();
      if (await waitForStatus(/上限/)) {
        if (!(await buttonHasFocus())) fail(`${label}: focus left the button after an error`);
        if ((await button.getAttribute("aria-disabled")) !== null) fail(`${label}: the button stays disabled after an error`);
        if (await page.locator("[data-contact-result]").isVisible()) fail(`${label}: an address is shown after an error`);
      }

      // 2. Success: the address appears as a mailto link and receives focus.
      state.workerStatus = 200;
      await pressButton();
      const link = page.locator("[data-contact-result] a");
      try {
        await link.waitFor({ state: "visible", timeout: 5000 });
      } catch {
        fail(`${label}: no address after a successful check (status "${await statusText()}")`);
        continue;
      }
      await waitForStatus(/メールアドレスを表示しました/);
      if ((await link.textContent()) !== TEST_EMAIL) fail(`${label}: link text is "${await link.textContent()}"`);
      if (!(await link.getAttribute("href"))?.startsWith(`mailto:${TEST_EMAIL}?`)) {
        fail(`${label}: link href is "${await link.getAttribute("href")}"`);
      }
      const linkHasFocus = await page.evaluate(
        () => document.activeElement === document.querySelector("[data-contact-result] a"),
      );
      if (!linkHasFocus) fail(`${label}: focus did not move to the address`);
      if (await button.isVisible()) fail(`${label}: the button is still shown with the address`);
      if (await page.locator("[data-contact-widget]").isVisible()) fail(`${label}: the Turnstile widget was not removed`);

      if (state.turnstileLoads !== 1) fail(`${label}: Turnstile was loaded ${state.turnstileLoads} times, expected once`);
      const renders = await page.evaluate(() => window.__turnstileRenders);
      for (const render of renders) {
        if (render.sitekey !== TEST_SITEKEY || render.action !== "show-email" || render.language !== "ja") {
          fail(`${label}: turnstile.render got ${JSON.stringify(render)}`);
        }
      }
      for (const request of state.workerRequests) {
        if (request.method !== "POST" || request.body !== `token=${encodeURIComponent(TEST_TOKEN)}`) {
          fail(`${label}: the Worker got ${request.method} ${request.body}`);
        }
        if (request.origin !== server.origin) fail(`${label}: the Worker got Origin ${request.origin}`);
      }

      const results = await new AxeBuilder({ page }).withTags(AXE_TAGS).analyze();
      for (const violation of results.violations) {
        const targets = violation.nodes.map((node) => node.target.join(" ")).slice(0, 5).join(", ");
        fail(`${label}: axe ${violation.id} (${violation.impact}) with the address shown: ${violation.help} → ${targets}`);
      }

      // 3. Turnstile cannot be loaded (for example a content blocker): the visitor is told so.
      await page.reload({ waitUntil: "load" });
      state.blockTurnstile = true;
      await pressButton();
      if (await waitForStatus(/読み込めませんでした/)) {
        if ((await button.getAttribute("aria-disabled")) !== null) fail(`${label}: the button stays disabled when Turnstile is blocked`);
      }

      if (failures.length === failuresBefore) console.log(`✓ ${label}: error, success and blocked Turnstile`);
    }

    for (const href of external) {
      if (!isAllowedExternal(new URL(href).hostname)) fail(`[${mode.name}] contact button: request to ${href}`);
    }
    await context.close();
  }
}

if (failures.length > 0) {
  console.error(`\n${failures.length} problem(s) found.`);
  process.exit(1);
}
console.log("\nAll pages passed.");
