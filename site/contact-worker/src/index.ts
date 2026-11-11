// SPDX-License-Identifier: Apache-2.0

import { handleRequest, type Env } from "./app";

export default {
  fetch: (request, env) => handleRequest(request, env),
} satisfies ExportedHandler<Env>;
