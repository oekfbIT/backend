import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { S3Client } from "@aws-sdk/client-s3";
import { Upload } from "@aws-sdk/lib-storage";
import { config } from "./config.mjs";

const run = promisify(execFile);

const s3 = () => new S3Client({
  endpoint: config.spaces.endpoint, region: config.spaces.region,
  credentials: { accessKeyId: config.spaces.key, secretAccessKey: config.spaces.secret },
});

/** Multipart upload to DigitalOcean Spaces; returns the public CDN URL. */
export async function upload(file, key, contentType) {
  const { bucket, cdnBase } = config.spaces;
  if (!bucket || !config.spaces.key) throw new Error("SPACES_* not configured in BE/.env");
  await new Upload({
    client: s3(),
    params: { Bucket: bucket, Key: key, Body: fs.createReadStream(file), ContentType: contentType, ACL: "public-read",
      CacheControl: "public, max-age=31536000, immutable" },
    queueSize: 4, partSize: 16 * 1024 * 1024,
  }).done();
  return `${cdnBase}/${key}`;
}

/** Re-mux with faststart so browsers can start playing before the whole file is loaded. */
export async function faststart(input) {
  const output = input.replace(/\.mp4$/, ".web.mp4");
  await run("ffmpeg", ["-y", "-i", input, "-c", "copy", "-movflags", "+faststart", output], { maxBuffer: 1 << 26 });
  return output;
}

/** Cuts one highlight (re-encoded for exact start) plus a thumbnail at the event moment. */
export async function cutClip(input, { start, end, event }, outDir, name) {
  fs.mkdirSync(outDir, { recursive: true });
  const clip = path.join(outDir, `${name}.mp4`);
  const thumb = path.join(outDir, `${name}.jpg`);
  await run("ffmpeg", ["-y", "-ss", String(start), "-to", String(end), "-i", input,
    "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-c:a", "aac", "-movflags", "+faststart", clip], { maxBuffer: 1 << 26 });
  await run("ffmpeg", ["-y", "-ss", String(event), "-i", input, "-frames:v", "1", "-q:v", "3", thumb], { maxBuffer: 1 << 26 });
  return { clip, thumb };
}
