// SPDX-License-Identifier: Apache-2.0

import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";

// Setup files may run more than once; applyD1Migrations() only applies missing migrations.
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
