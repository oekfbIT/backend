import { config } from "./config.mjs";

async function call(method, endpoint, body) {
  const response = await fetch(`${config.backendUrl}/veo-sync/${endpoint}`, {
    method,
    headers: { "Content-Type": "application/json", "X-Veo-Sync-Key": config.serviceKey() },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`${method} ${endpoint} → ${response.status}: ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : null;
}

export const backend = {
  known: () => call("GET", "known"),
  matchInfo: (id) => call("GET", `match/${id}`),
  claimJob: () => call("POST", "jobs/claim"),
  jobLog: (id, lines, status) => call("POST", `jobs/${id}/log`, { lines, ...(status ? { status } : {}) }),
  upsertRecording: (payload) => call("POST", "recordings", payload),
  setVideo: (slug, videoUrl) => call("POST", `recordings/${encodeURIComponent(slug)}/video`, { video_url: videoUrl }),
  addClips: (slug, clips) => call("POST", `recordings/${encodeURIComponent(slug)}/clips`, clips),
};
