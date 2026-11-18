import { config as load } from "dotenv";
import { fileURLToPath } from "node:url";
import path from "node:path";

// Reads the backend's .env (BE/.env), so all secrets live in one place.
const here = path.dirname(fileURLToPath(import.meta.url));
load({ path: path.resolve(here, "../../../.env") });

const need = (key) => {
  const value = process.env[key];
  if (!value) throw new Error(`Missing ${key} in BE/.env`);
  return value;
};

export const config = {
  veoEmail: () => need("VEO_EMAIL"),
  veoPassword: () => need("VEO_PASSWORD"),
  clubUrl: process.env.VEO_CLUB_URL || "https://app.veo.co/clubs/osterreichischer-kleinfeld-fuball-bund/recordings/",
  backendUrl: (process.env.VEO_SYNC_BACKEND_URL || "http://localhost:8080").replace(/\/+$/, ""),
  serviceKey: () => need("VEO_SYNC_SERVICE_KEY"),
  headless: process.env.VEO_SYNC_HEADLESS !== "false",
  maxPerRun: Number(process.env.VEO_SYNC_MAX_PER_RUN || 5),
  clipBefore: Number(process.env.VEO_CLIP_SECONDS_BEFORE || 10),
  clipAfter: Number(process.env.VEO_CLIP_SECONDS_AFTER || 6),
  // Which Veo clips go to the CDN (goal, shot, penalty, save). Default: goals only.
  clipTypes: (process.env.VEO_CLIP_TYPES || "goal").split(",").map((t) => t.trim()),
  // Full match recording (several GB) – off by default.
  fullVideo: process.env.VEO_SYNC_FULL_VIDEO === "true",
  // Delete leftover clips of earlier runs from Spaces – off by default.
  pruneCdn: process.env.VEO_SYNC_PRUNE_CDN === "true",
  spaces: {
    endpoint: process.env.SPACES_ENDPOINT,          // e.g. https://fra1.digitaloceanspaces.com
    region: process.env.SPACES_REGION || "fra1",
    bucket: process.env.SPACES_BUCKET,
    key: process.env.SPACES_KEY,
    secret: process.env.SPACES_SECRET,
    cdnBase: (process.env.SPACES_CDN_BASE || "").replace(/\/+$/, ""), // e.g. https://bucket.fra1.cdn.digitaloceanspaces.com
  },
  paths: {
    auth: path.resolve(here, "../.auth/veo-state.json"),
    captures: path.resolve(here, "../captures"),
    downloads: path.resolve(here, "../downloads"),
  },
};
