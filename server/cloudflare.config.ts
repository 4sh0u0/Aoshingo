// SPDX-License-Identifier: Apache-2.0
// Cloudflare Worker that receives opt-in field data from the Aoshingo iOS app.
// Deployed with the Cloudflare CLI (`npm run deploy` = D1 migrations, then `cf deploy`) by Workers
// Builds (Cloudflare's Git integration) on every push to main that touches server/. See README.md
// for the setup and docs/field-data-api.md for the API contract.
//
// This file is the deploy configuration. wrangler.jsonc is kept only for the tests, because
// @cloudflare/vitest-plugin reads it. When you change a binding, a variable or a trigger, change
// both files.

import { bindings, defineConfig, triggers } from "cf/config";

export default defineConfig({
  worker: {
    name: "aoshingo-reports",
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

    triggers: [
      // Daily at 18:00 UTC = 03:00 JST: fold expired reports into aggregates, drop old challenges.
      triggers.scheduled({ schedule: "0 18 * * *" }),
    ],

    env: {
      // Apple Developer team ID of the app (not secret).
      APPLE_TEAM_ID: bindings.text("XTCC8DPHBX"),
      APP_BUNDLE_ID: bindings.text("io.github.4sh0u0.aoshingo"),
      // "true" accepts keys from the App Attest development environment (debug builds).
      ALLOW_DEVELOPMENT_ATTESTATION: bindings.text("false"),
      RETENTION_DAYS: bindings.text("90"),
      TOKEN_TTL_SECONDS: bindings.text("21600"),

      // HMAC key for upload tokens (at least 32 characters). The value is never stored in the
      // repository: the first deploy uploads it with `cf deploy --secrets-file`, and later deploys
      // keep it. See README.md.
      TOKEN_SECRET: bindings.secret(),

      // Created in APAC. The ID is not a secret. `npm run deploy` applies migrations/ first
      // (`cf d1 migrations apply <ID> --dir migrations`).
      DB: bindings.d1({
        name: "aoshingo-reports",
        id: "ca8ff962-c094-4c66-b9fd-bbf2189ef549",
      }),

      // Workers Rate Limiting. Periods can only be 10 or 60 seconds; counters are per Cloudflare
      // location. The namespace must be unique within the Cloudflare account.
      // POST /v1/reports, keyed by the upload token's random ID.
      REPORTS_RATE_LIMITER: bindings.rateLimit({
        namespace: "1001",
        simple: { limit: 6, period: 60 },
      }),
      // POST /v1/challenge, /v1/attest and /v1/token, each with its own fixed global key.
      AUTH_RATE_LIMITER: bindings.rateLimit({
        namespace: "1002",
        simple: { limit: 30, period: 60 },
      }),
    },
  },
});
