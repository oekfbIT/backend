import fs from "node:fs/promises";
import path from "node:path";
import { chromium } from "playwright";
import { config } from "./config.mjs";

/**
 * Browser session on app.veo.co. Reuses the saved login (.auth/veo-state.json) and records every JSON
 * response the Veo web app loads, so we read Veo's own structured data instead of the screen.
 */
export async function openVeo() {
  const browser = await chromium.launch({ headless: config.headless });
  const hasState = await fs.access(config.paths.auth).then(() => true, () => false);
  const context = await browser.newContext({ acceptDownloads: true, ...(hasState ? { storageState: config.paths.auth } : {}) });
  const page = await context.newPage();
  const captured = [];
  page.on("response", async (response) => {
    const type = response.headers()["content-type"] || "";
    if (!type.includes("application/json")) return;
    try { captured.push({ url: response.url(), status: response.status(), body: await response.json() }); } catch { /* ignore */ }
  });
  return { browser, context, page, captured };
}

/**
 * Opens a page without waiting for "networkidle": Veo pages stream video and poll, so the network
 * never goes quiet. Wait for the DOM, then give the app a few seconds to load its data.
 */
export async function open(page, url, settleMs = 6000) {
  await page.goto(url, { waitUntil: "domcontentloaded", timeout: 60000 });
  await settle(page, settleMs);
}

async function settle(page, ms) {
  await page.waitForLoadState("networkidle", { timeout: ms }).catch(() => {});
}

export async function ensureLoggedIn({ page, context }) {
  await open(page, config.clubUrl);
  if (!/login|signin|auth/i.test(page.url())) return;
  // DRAFT: selectors to verify on the real login page (run with VEO_SYNC_HEADLESS=false once).
  await page.fill('input[type="email"], input[name="email"]', config.veoEmail());
  await page.fill('input[type="password"], input[name="password"]', config.veoPassword());
  await Promise.all([page.waitForURL((u) => !/login|signin|auth/i.test(u.toString()), { timeout: 60000 }).catch(() => {}), page.click('button[type="submit"]')]);
  if (/login|signin|auth/i.test(page.url())) throw new Error("Veo login failed (check credentials / 2FA)");
  await fs.mkdir(path.dirname(config.paths.auth), { recursive: true });
  await context.storageState({ path: config.paths.auth });
  await open(page, config.clubUrl);
}

/** All recordings of the club library: slug, title, date text, duration text. Scrolls until all are loaded. */
export async function listRecordings({ page }) {
  await open(page, config.clubUrl);
  let previous = -1;
  for (let i = 0; i < 60; i++) {
    const count = await page.locator('a[href*="/matches/"]').count();
    if (count === previous) break;
    previous = count;
    // DRAFT: the library may use a "load more" button instead of infinite scroll.
    const more = page.getByRole("button", { name: /more|mehr|load/i });
    if (await more.count()) await more.first().click().catch(() => {});
    await page.mouse.wheel(0, 20000);
    await page.waitForTimeout(1200);
  }
  const rows = await page.$$eval('a[href*="/matches/"]', (links) => links.map((a) => {
    const slug = (a.getAttribute("href") || "").match(/\/matches\/([^/?#]+)/)?.[1];
    const card = a.closest("li, article, div");
    return { slug, text: (card?.innerText || a.innerText || "").trim() };
  }));
  const bySlug = new Map();
  for (const row of rows) if (row.slug && !bySlug.has(row.slug)) bySlug.set(row.slug, row);
  return [...bySlug.values()].map(({ slug, text }) => {
    const lines = text.split("\n").map((l) => l.trim()).filter(Boolean);
    const dateLine = lines.find((l) => /\d{1,2}\s+[A-Z]{3}\s+\d{4}/i.test(l));
    const title = lines.find((l) => / vs\.? /i.test(l)) || lines.find((l) => l !== dateLine && !/^\d{2}:\d{2}/.test(l)) || slug;
    const duration = lines.find((l) => /^\d{2}:\d{2}:\d{2}$/.test(l));
    return { slug, title, dateText: dateLine, durationText: duration };
  });
}

/** Opens a match and every side-panel tab so the web app loads all its data; returns the captured JSON. */
export async function captureMatch(veo, slug) {
  veo.captured.length = 0;
  await open(veo.page, `https://app.veo.co/matches/${slug}/`, 10000);
  // Tabs on the right side (Analytics, Player Moments, Clips, Events, Lineup, Report). They may be buttons, tabs or links.
  for (const name of [/events|ereignisse|highlights/i, /clips/i, /analytics|stats|statistik/i, /lineup|aufstellung|players/i, /player moments/i, /report|bericht/i]) {
    for (const role of ["tab", "button", "link"]) {
      const tab = veo.page.getByRole(role, { name });
      if (await tab.count()) {
        await tab.first().click({ timeout: 5000 }).catch(() => {});
        await settle(veo.page, 4000);
        break;
      }
    }
  }
  await settle(veo.page, 5000);
  console.log(`  ${veo.captured.length} JSON-Antworten von Veo gelesen`);
  return [...veo.captured];
}

/** Downloads the full recording via the "Download" button. DRAFT: the dialog may offer several versions. */
export async function downloadRecording({ page }, slug) {
  await fs.mkdir(config.paths.downloads, { recursive: true });
  await open(page, `https://app.veo.co/matches/${slug}/`, 8000);
  const [download] = await Promise.all([
    page.waitForEvent("download", { timeout: 15 * 60 * 1000 }),
    (async () => {
      await page.getByRole("button", { name: /download/i }).first().click();
      // If a dialog with options opens, choose the full recording (follow-cam) and confirm.
      const full = page.getByText(/full recording|recording|follow/i);
      if (await full.count()) await full.first().click().catch(() => {});
      const confirm = page.getByRole("button", { name: /^download$/i });
      if (await confirm.count() > 1) await confirm.last().click().catch(() => {});
    })(),
  ]);
  const file = path.join(config.paths.downloads, `${slug}.mp4`);
  await download.saveAs(file);
  return file;
}
