// SPDX-License-Identifier: Apache-2.0
// Cloudflare Worker behind the website's 「メールアドレスを表示」 button (site/public/assets/contact.js).
// Deployed with the Cloudflare CLI (`npm run deploy` = `cf deploy`) by Workers Builds on every push to
// main that touches site/contact-worker/. See README.md for the setup.

import { bindings, defineConfig } from "cf/config";

export default defineConfig({
  worker: {
    name: "aoshingo-contact",
    compatibilityDate: "2026-10-01",
    entrypoint: "src/index.ts",
    workersDev: true,
    previewUrls: false,

    // Privacy: no Workers Logs, invocation logs or traces. The code itself never logs.
    observability: {
      enabled: false,
      logs: { enabled: false, invocationLogs: false },
      traces: { enabled: false },
    },

    env: {
      // The website. Comma-separated.
      ALLOWED_ORIGINS: bindings.text("https://aoshingo.4sh.es"),
      // Hostnames Siteverify may report. Must match the hostnames of the Turnstile widget.
      ALLOWED_HOSTNAMES: bindings.text("aoshingo.4sh.es"),

      // Neither value is stored in the repository: the first deploy uploads them with
      // `cf deploy --secrets-file`, and later deploys keep them. See README.md.
      TURNSTILE_SECRET_KEY: bindings.secret(),
      CONTACT_EMAIL: bindings.secret(),

      // Workers Rate Limiting, counted after a successful verification with a fixed key. Periods
      // can only be 10 or 60 seconds; counters are per Cloudflare location. The namespace must be
      // unique within the Cloudflare account (aoshingo-reports uses 1001 and 1002).
      REVEAL_RATE_LIMITER: bindings.rateLimit({
        namespace: "1003",
        simple: { limit: 10, period: 60 },
      }),
    },
  },
});
