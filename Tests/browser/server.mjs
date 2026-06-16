// Minimal static server for the SameDesk browser client. Serves the REAL,
// unmodified assets (client.html at /, client.js at /client.js) straight from
// Sources/, so the smoke tests exercise exactly what ships. No token gate here —
// auth is mocked at the WebSocket layer in the tests.
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const clientDir = join(here, "..", "..", "Sources", "SameDesk", "Client");
const port = Number(process.argv[2]) || 4173;

const routes = {
  "/": ["client.html", "text/html; charset=utf-8"],
  "/client.html": ["client.html", "text/html; charset=utf-8"],
  "/client.js": ["client.js", "application/javascript; charset=utf-8"],
};

createServer(async (req, res) => {
  const path = (req.url || "/").split("?")[0];
  const route = routes[path];
  if (!route) {
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found");
    return;
  }
  try {
    const body = await readFile(join(clientDir, route[0]));
    res.writeHead(200, { "content-type": route[1] });
    res.end(body);
  } catch (err) {
    res.writeHead(500, { "content-type": "text/plain" });
    res.end(String(err));
  }
}).listen(port, "127.0.0.1", () => {
  console.log(`SameDesk client served on http://127.0.0.1:${port}/`);
});
