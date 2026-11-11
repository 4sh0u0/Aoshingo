// SPDX-License-Identifier: Apache-2.0

import type { D1Migration } from "cloudflare:test";
import type { Env as WorkerEnv } from "../src/env";

declare global {
  namespace Cloudflare {
    interface Env extends WorkerEnv {
      /** Defined in vitest.config.ts. */
      TEST_MIGRATIONS: D1Migration[];
    }
    interface GlobalProps {
      mainModule: typeof import("../src/index");
    }
  }
}
