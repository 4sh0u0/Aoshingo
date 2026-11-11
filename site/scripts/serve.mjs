// SPDX-License-Identifier: Apache-2.0
//
// Minimal static server for previewing site/public the way GitHub Pages serves it:
// under the /Aoshingo/ base path, with index.html for directories, a redirect to the
// trailing-slash URL, and 404.html for missing paths.
//
//   npm run serve            -> http://localhost:8000/Aoshingo/
//   PORT=9000 npm run serve

import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const BASE_PATH = "/Aoshingo/";
export const PUBLIC_DIR = fileURLToPath(new URL("../public/", import.meta.url));

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml; charset=utf-8",
  ".json": "application/json; charset=utf-8",
};

async function isFile(file) {
  try {
    return (await stat(file)).isFile();
  } catch {
    return false;
  }
}

async function isDirectory(file) {
  try {
    return (await stat(file)).isDirectory();
  } catch {
    return false;
  }
}

function send(res, status, file) {
  res.writeHead(status, {
    "content-type": TYPES[path.extname(file)] ?? "application/octet-stream",
    "cache-control": "no-store",
  });
  createReadStream(file).pipe(res);
}

async function handle(root, req, res) {
  const url = new URL(req.url, "http://localhost");
  const notFound = path.join(root, "404.html");
  if (!url.pathname.startsWith(BASE_PATH)) {
    if (url.pathname === BASE_PATH.slice(0, -1) || url.pathname === "/") {
      res.writeHead(301, { location: BASE_PATH });
      return res.end();
    }
    return send(res, 404, notFound);
  }
  let relative;
  try {
    relative = decodeURIComponent(url.pathname.slice(BASE_PATH.length));
  } catch {
    return send(res, 400, notFound);
  }
  const file = path.resolve(root, relative);
  if (file !== root && !file.startsWith(root + path.sep)) {
    return send(res, 404, notFound);
  }
  if (await isDirectory(file)) {
    if (!url.pathname.endsWith("/")) {
      res.writeHead(301, { location: `${url.pathname}/${url.search}` });
      return res.end();
    }
    const index = path.join(file, "index.html");
    return (await isFile(index)) ? send(res, 200, index) : send(res, 404, notFound);
  }
  if (await isFile(file)) return send(res, 200, file);
  if (await isFile(`${file}.html`)) return send(res, 200, `${file}.html`);
  return send(res, 404, notFound);
}

/** Starts the server. `port: 0` picks a free port. Resolves to `{ origin, url, close }`. */
export function startServer({ port = 0, host = "127.0.0.1", root = PUBLIC_DIR } = {}) {
  const resolvedRoot = path.resolve(root);
  const server = createServer((req, res) => {
    handle(resolvedRoot, req, res).catch((error) => {
      res.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
      res.end(String(error));
    });
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, host, () => {
      const { port: actual } = server.address();
      const origin = `http://${host}:${actual}`;
      resolve({
        origin,
        url: `${origin}${BASE_PATH}`,
        close: () => new Promise((done) => server.close(done)),
      });
    });
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { url } = await startServer({ port: Number(process.env.PORT ?? 8000), host: "localhost" });
  console.log(`Serving site/public at ${url}`);
}
