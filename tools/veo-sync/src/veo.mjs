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
  const context = await browser.newContext({ acceptDownloads: true, viewport: { width: 1600, height: 1000 }, ...(hasState ? { storageState: config.paths.auth } : {}) });
  const page = await context.newPage();
  const captured = [];
  const auth = { headers: null };
  page.on("request", (request) => {
    const url = request.url();
    if (/^https:\/\/app\.veo\.co\/api\//.test(url) && request.method() === "GET") {
      const h = { ...request.headers() };
      for (const k of ["host", "content-length", "cookie", "accept-encoding", ":authority", ":method", ":path", ":scheme"]) delete h[k];
      auth.headers = h;
    }
  });
  page.on("response", async (response) => {
    const type = response.headers()["content-type"] || "";
    if (!type.includes("application/json")) return;
    try { captured.push({ url: response.url(), status: response.status(), body: await response.json() }); } catch { /* ignore */ }
  });
  return { browser, context, page, captured, auth };
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

/** GET a Veo URL the way the web app does (same headers + cookies). Returns { status, body } or null. */
export async function veoGet(veo, url, attempts = 3) {
  for (let i = 1; i <= attempts; i++) {
    try {
      const r = await veo.context.request.get(url, { headers: veo.auth.headers || {}, timeout: 30000 });
      if (r.ok()) return { url, status: r.status(), body: await r.json() };
      if (r.status() === 404) return { url, status: 404, body: null };
      if (i === attempts) return { url, status: r.status(), body: null };
    } catch (e) {
      if (i === attempts) return { url, status: 0, body: null, error: e.message };
    }
    await new Promise((res) => setTimeout(res, 1500 * i));
  }
  return null;
}

/**
 * Makes sure every response the parser needs is present. The page loads them lazily (slow servers often
 * miss some), so anything missing is fetched directly from Veo's API with the app's own headers.
 */
export async function ensureMatchData(veo, slug, captured) {
  const has = (re) => captured.some((c) => re.test(c.url) && c.status < 300 && c.body);
  const add = async (url, label) => {
    const res = await veoGet(veo, url);
    if (res?.body) { captured.push(res); return true; }
    console.log(`  ${label}: nicht geladen (HTTP ${res?.status ?? "?"})`);
    return false;
  };
  const base = `https://app.veo.co/api/app/matches/${slug}`;
  if (!has(/\/api\/app\/matches\/[^/]+\/$/)) await add(`${base}/`, "Spieldaten");
  const match = captured.find((c) => /\/api\/app\/matches\/[^/]+\/$/.test(c.url) && c.body?.slug === slug)?.body
    || captured.find((c) => /\/api\/app\/matches\/[^/]+\/$/.test(c.url) && c.body?.id)?.body;
  const id = match?.id;
  if (!has(/\/periods\/$/)) await add(`${base}/periods/`, "Halbzeiten");
  if (!has(/\/videos\/$/)) await add(`${base}/videos/`, "Videos");
  if (!has(/\/highlights\//)) await add(`${base}/highlights/?include_ai=true`, "Clips");
  if (id && !has(/\/match-events/)) await add(`https://app.veo.co/api/mes/v2/${id}/match-events?aggregatedDuels=true`, "Ereignisse");
  if (id && !has(/\/physical-metrics/)) await add(`https://app.veo.co/api/mes/v2/${id}/physical-metrics`, "Laufdaten");
  if (id && !has(/\/match-details/)) {
    const periods = captured.find((c) => /\/periods\/$/.test(c.url) && Array.isArray(c.body))?.body || [];
    const host = captured.map((c) => c.url.match(/^(https:\/\/[^/]+cloudfront\.net)\/recordings\//)?.[1]).find(Boolean) || "https://dt3kfuz4eo879.cloudfront.net";
    if (periods.length) {
      const filters = periods.map((p) => `filters=${p.timeframe[0]}%2C${p.timeframe[1]}`).join("&");
      await add(`${host}/recordings/${id}/match-details?${filters}`, "Pässe/Ballbesitz");
    }
  }
  return captured;
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
export async function listRecordings(veo) {
  const { page } = veo;
  await open(page, config.clubUrl);
  // Fast path: Veo's own match list API (needs the headers seen while the library page loaded).
  const club = config.clubUrl.match(/\/clubs\/([^/]+)/)?.[1];
  if (club) {
    const res = await veoGet(veo, `https://app.veo.co/api/app/matches/?ordering=-created&club=${club}&page_size=200`);
    const list = Array.isArray(res?.body) ? res.body : res?.body?.results;
    if (list?.length) {
      return list.filter((m) => m.slug).map((m) => ({ slug: m.slug, title: m.title || m.slug, recordedAt: m.start || null, durationSeconds: m.duration ?? null, dateText: null, durationText: null }));
    }
    console.log(`  Bibliothek über API nicht lesbar (HTTP ${res?.status ?? "?"}) – lese die Seite`);
  }
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

/**
 * Opens a match and every panel of the icon rail on the right (stats, lineup, clips, events, …) so the
 * web app loads all its data. Returns the captured JSON plus, per panel, its visible text and a screenshot
 * (used to write exact parsers and as a fallback when a panel has no JSON of its own).
 */
export async function captureMatch(veo, slug, debugDir) {
  const { page } = veo;
  veo.captured.length = 0;
  await open(page, `https://app.veo.co/matches/${slug}/`, 60000);
  const panels = [];
  if (debugDir) await page.screenshot({ path: `${debugDir}/panel-00-start.png` }).catch(() => {});

  // The rail = small icon buttons in the right-most 120 px of the window. Click each one in turn.
  const railCount = await page.evaluate(() => {
    const w = window.innerWidth;
    const buttons = [...document.querySelectorAll("button, a, [role=button], [role=tab]")].filter((el) => {
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.width < 90 && r.height < 90 && r.left > w - 120 && r.top > 100;
    });
    buttons.forEach((el, i) => el.setAttribute("data-veo-sync-rail", String(i)));
    return buttons.length;
  });
  console.log(`  ${railCount} Seitenleisten-Buttons gefunden`);

  for (let i = 0; i < railCount; i++) {
    const button = page.locator(`[data-veo-sync-rail="${i}"]`);
    const label = (await button.getAttribute("aria-label").catch(() => null)) || (await button.getAttribute("title").catch(() => null)) || `rail-${i}`;
    if (/help|hilfe|\+|add|new|lightning/i.test(label)) continue;
    await page.keyboard.press("Escape").catch(() => {});
    await button.click({ timeout: 5000 }).catch(() => {});
    await settle(page, 4000);
    // Lists are virtualised: scroll the open panel to the bottom so every item loads.
    for (let k = 0; k < 15; k++) {
      await page.mouse.move(1350, 600);
      await page.mouse.wheel(0, 4000);
      await page.waitForTimeout(400);
    }
    // Expand the analytics sections (Stats, Shot map, Pass location, Possession location, Heat map).
    for (const section of [/^stats$/i, /shot map/i, /pass location/i, /possession location/i, /heat ?map/i]) {
      const header = page.getByText(section).first();
      if (await header.count().catch(() => 0)) { await header.click({ timeout: 3000 }).catch(() => {}); await settle(page, 2500); }
    }
    await settle(page, 2000);
    const text = await page.evaluate(() => {
      const w = window.innerWidth;
      const panel = [...document.querySelectorAll("aside, section, div")].find((el) => {
        const r = el.getBoundingClientRect();
        return r.left > w * 0.6 && r.left < w - 120 && r.height > 400 && r.width > 250 && r.width < 700;
      });
      return panel ? panel.innerText : "";
    });
    panels.push({ index: i, label, text });
    if (debugDir) await page.screenshot({ path: `${debugDir}/panel-${String(i + 1).padStart(2, "0")}.png` }).catch(() => {});
  }
  console.log(`  ${veo.captured.length} JSON-Antworten, ${panels.length} Panels gelesen`);
  return { captured: [...veo.captured], panels };
}

/** Downloads the full recording via the "Download" button. DRAFT: the dialog may offer several versions. */
export async function downloadRecording({ page }, slug) {
  await fs.mkdir(config.paths.downloads, { recursive: true });
  await open(page, `https://app.veo.co/matches/${slug}/`, 8000);
  const [download] = await Promise.all([
    page.waitForEvent("download", { timeout: 2 * 60 * 1000 }),
    (async () => {
      await page.getByRole("button", { name: /download/i }).first().click();
      // If a dialog with options opens, choose the full recording (follow-cam) and confirm.
      const full = page.getByText(/full recording|recording|follow/i);
      if (await full.count()) await full.first().click().catch(() => {});
      const confirm = page.getByRole("button", { name: /^download$/i });
      if (await confirm.count() > 1) await confirm.last().click().catch(() => {});
    })(),
  ]);
  console.log(`  Download gestartet: ${download.suggestedFilename()}`);
  const file = path.join(config.paths.downloads, `${slug}.mp4`);
  await download.saveAs(file);
  console.log("  Download fertig");
  return file;
}
