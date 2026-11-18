import fs from "node:fs";
import { pipeline } from "node:stream/promises";
import { Readable } from "node:stream";

/**
 * Downloads a URL to a file with retries and resume (HTTP Range), using the browser's Veo cookies.
 * A dropped connection continues where it stopped instead of starting over.
 */
export async function downloadFile(url, file, { cookies = "", attempts = 6, label = "Download" } = {}) {
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const have = fs.existsSync(file) ? fs.statSync(file).size : 0;
    try {
      const response = await fetch(url, { headers: { ...(cookies ? { Cookie: cookies } : {}), ...(have ? { Range: `bytes=${have}-` } : {}) } });
      if (response.status === 416) return file; // already complete
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const resumed = response.status === 206;
      const total = Number(response.headers.get("content-length") || 0) + (resumed ? have : 0);
      if (!resumed && have) fs.truncateSync(file, 0);
      let done = resumed ? have : 0, lastLog = Date.now();
      const body = Readable.fromWeb(response.body);
      body.on("data", (chunk) => {
        done += chunk.length;
        if (Date.now() - lastLog > 15000 && total) { lastLog = Date.now(); console.log(`  ${label}: ${Math.round((done / total) * 100)} % von ${Math.round(total / 1048576)} MB`); }
      });
      await pipeline(body, fs.createWriteStream(file, { flags: resumed ? "a" : "w" }));
      if (total && fs.statSync(file).size < total) throw new Error("unvollständig");
      return file;
    } catch (error) {
      lastError = error;
      const wait = Math.min(60, 5 * 2 ** (attempt - 1));
      console.log(`  ${label}: Versuch ${attempt}/${attempts} fehlgeschlagen (${error.message}) – neuer Versuch in ${wait} s`);
      await new Promise((r) => setTimeout(r, wait * 1000));
    }
  }
  throw new Error(`${label} nach ${attempts} Versuchen fehlgeschlagen: ${lastError?.message}`);
}

export async function cookieHeader(context) {
  return (await context.cookies()).map((c) => `${c.name}=${c.value}`).join("; ");
}
