// SPDX-License-Identifier: Apache-2.0

// Cloudflare Worker entry point for the Aoshingo field-data API (docs/field-data-api.md).

import { createApp } from "./app";
import type { Env } from "./env";

const app = createApp();

export default {
  fetch: (request, env, ctx) => app.fetch(request, env, ctx),
  scheduled: (controller, env, ctx) => app.scheduled(controller, env, ctx),
} satisfies ExportedHandler<Env>;
