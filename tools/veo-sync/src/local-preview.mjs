import { createReadStream, existsSync } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { Readable, pipeline } from "node:stream";
import { fileURLToPath } from "node:url";

const previewURL = new URL(process.env.VEO_PREVIEW_URL || "http://localhost:8083");
const backend = new URL("http://127.0.0.1:8080");
const downloads = fileURLToPath(new URL("../downloads/", import.meta.url));
const matchPattern = /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i;
const clipPath = /^\/matches\/([^/]+)\/clips\/([\w-]+\.(mp4|jpg))$/;
const clipFeed = /^\/webClient\/(?:match\/[^/]+\/(?:videos|clips)|(?:team|player)\/[^/]+\/clips)$/;

const folders = new Map(process.argv.slice(2).map((argument) => {
  const [match, slug] = argument.split("=");
  if (!matchPattern.test(match) || !slug || !/^[\w-]+$/.test(slug)) {
    throw new Error("Expected arguments in the form match-uuid=veo-slug.");
  }
  return [match.toLowerCase(), resolve(downloads, slug)];
}));
if (folders.size === 0) throw new Error("Supply at least one match-uuid=veo-slug mapping.");

function cacheFile(pathname) {
  const match = clipPath.exec(pathname);
  if (!match) return undefined;
  const folder = folders.get(match[1].toLowerCase());
  return folder && { path: resolve(folder, match[2]), type: match[3] === "mp4" ? "video/mp4" : "image/jpeg" };
}

function localClipURL(value) {
  if (typeof value !== "string" || !URL.canParse(value)) return value;
  const url = new URL(value);
  const file = cacheFile(url.pathname);
  return file && existsSync(file.path) ? new URL(url.pathname, previewURL).href : value;
}

async function serveClip(request, response, file) {
  const size = (await stat(file.path)).size;
  const headers = { "Content-Type": file.type, "Accept-Ranges": "bytes" };
  const range = request.headers.range;
  const bounds = range && /^bytes=(\d*)-(\d*)$/.exec(range);
  const start = bounds ? (bounds[1] ? Number(bounds[1]) : Math.max(0, size - Number(bounds[2]))) : 0;
  const end = bounds?.[1] && bounds[2] ? Math.min(Number(bounds[2]), size - 1) : size - 1;
  if (range && (!bounds || start > end || start >= size)) {
    response.writeHead(416, { ...headers, "Content-Range": `bytes */${size}` }).end();
    return;
  }
  if (range) headers["Content-Range"] = `bytes ${start}-${end}/${size}`;
  response.writeHead(range ? 206 : 200, { ...headers, "Content-Length": end - start + 1 });
  if (request.method === "HEAD") response.end();
  else pipeline(createReadStream(file.path, { start, end }), response, () => {});
}

async function handle(request, response) {
  const url = new URL(request.url, previewURL);
  if (request.method !== "GET" && request.method !== "HEAD") {
    response.writeHead(405, { Allow: "GET, HEAD" }).end();
    return;
  }
  const file = cacheFile(url.pathname);
  if (file && existsSync(file.path)) return serveClip(request, response, file);

  if (url.pathname !== "/status" && !url.pathname.startsWith("/webClient/")) {
    response.writeHead(404).end();
    return;
  }

  const target = new URL(backend);
  target.pathname = url.pathname;
  target.search = url.search;
  const upstream = await fetch(target, { method: request.method, signal: AbortSignal.timeout(20000) });
  const contentType = upstream.headers.get("content-type") ?? "application/octet-stream";
  response.writeHead(upstream.status, { "Content-Type": contentType });

  if (upstream.ok && request.method === "GET" && clipFeed.test(url.pathname)) {
    const body = await upstream.text();
    const rewritten = JSON.parse(body, (key, value) =>
      key === "video_url" || key === "thumbnail_url" || key === "recording_url" ? localClipURL(value) : value,
    );
    response.end(JSON.stringify(rewritten));
  } else if (upstream.body) {
    pipeline(Readable.fromWeb(upstream.body), response, () => {});
  } else {
    response.end();
  }
}

createServer((request, response) => {
  handle(request, response).catch((error) => {
    console.error(error.message);
    if (response.headersSent) response.destroy();
    else response.writeHead(502).end();
  });
}).listen(Number(previewURL.port || 8083), "0.0.0.0", () => {
  console.log(`Local Veo preview API: ${previewURL.origin}`);
});
