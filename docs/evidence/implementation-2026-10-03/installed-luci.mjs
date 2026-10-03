#!/usr/bin/env node
/*
 * Installed LuCI verification for #1147–#1150 (with prior native-expander regressions).
 * Read-only SSH identity probe; HTTP /ubus poll replies are explicitly replaced
 * with deterministic test rows so the installed parser and real DOM can be
 * exercised without claiming those rows came from guest logd.
 *
 * Run only after the disposable guest and final candidate are ready:
 *   FWLIVE_URL=http://127.0.0.1:13080 \
 *   OPENWRT_SSH_PORT=13022 node /tmp/fwlive-oct03/evidence/installed-luci.mjs
 *
 * Optional: FWLIVE_USERNAME=root, FWLIVE_PASSWORD=..., OPENWRT_HOST=127.0.0.1,
 * OPENWRT_SSH_USER=root, FWLIVE_EXPECT_VERSION=..., FWLIVE_SKIP_SSH_PREFLIGHT=1.
 */
import { createRequire } from "node:module";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";

const REPO = process.env.FWLIVE_REPO || "/home/lalbers/gitroot/fwlive";
const require = createRequire(path.join(REPO, "package.json"));
const { chromium } = require("playwright");

const BASE = (process.env.FWLIVE_URL || "http://127.0.0.1:13080").replace(
  /\/$/,
  "",
);
const HOST = process.env.OPENWRT_HOST || "127.0.0.1";
const SSH_PORT = process.env.OPENWRT_SSH_PORT || "13022";
const SSH_USER = process.env.OPENWRT_SSH_USER || "root";
const USERNAME = process.env.FWLIVE_USERNAME || "root";
const PASSWORD = process.env.FWLIVE_PASSWORD || "";
const EXPECT_VERSION = process.env.FWLIVE_EXPECT_VERSION || "";
const EXPECT_IPK =
	process.env.FWLIVE_IPK_PATH ||
	"/tmp/fwlive-oct03/evidence/artifacts/final/luci-app-fwlive_0.1.50-r1_all.ipk";
const VIEW_URL = `${BASE}/cgi-bin/luci/admin/status/fwlive`;
const SCREENSHOT = "/tmp/fwlive-oct03/evidence/u2-installed-luci.png";
const SIMPLE_SCREENSHOT = "/tmp/fwlive-oct03/evidence/u2-installed-luci-simple.png";
const PASS_ID = "99000101";
const DROP_ID = "99000102";
const PASS_ROW_ID = `log:${PASS_ID}`;
const DROP_ROW_ID = `log:${DROP_ID}`;
const RESOURCE_FILES = [
  ["fwlive/css.js", "/www/luci-static/resources/fwlive/css.js"],
  [
    "view/status/fwlive.js",
    "/www/luci-static/resources/view/status/fwlive.js",
  ],
  [
    "fwlive/table.js",
    "/www/luci-static/resources/fwlive/table.js",
  ],
  [
    "fwlive/chips.js",
    "/www/luci-static/resources/fwlive/chips.js",
  ],
];

const calls = [];
const injected = [];
const pageErrors = [];
let activeFixtureStage = null;
let pollRequestsInFlight = 0;

function parseCalls(postData) {
  if (!postData) return [];
  try {
    const parsed = JSON.parse(postData);
    const requests = Array.isArray(parsed) ? parsed : [parsed];
    return requests
      .map((request) => {
        const params = request && request.params;
        if (
          !Array.isArray(params) ||
          params.length < 3 ||
          request.method !== "call"
        )
          return null;
        return {
          id: request.id,
          object: params[1],
          method: params[2],
          args: params[3],
        };
      })
      .filter(Boolean);
  } catch {
    return [];
  }
}

function fixtureRows(stage) {
  const now = Math.floor(Date.now() / 1000);
  const refresh = stage === "refresh" ? " U2_REFRESHED_KEYED_ROW" : "";
  return [
    {
      id: Number(PASS_ID),
      time: now,
      msg:
        "fw4: ACCEPT IN=wan OUT= SRC=192.0.2.10 DST=198.51.100.10 " +
        "PROTO=TCP SPT=41001 DPT=443 MSG=<img src=x onerror=alert(1)>" +
        refresh,
    },
    {
      id: Number(DROP_ID),
      time: now - 1,
      msg:
        "fw4: DROP IN=wan OUT= SRC=192.0.2.11 DST=198.51.100.11 " +
        "PROTO=TCP SPT=41002 DPT=443",
    },
  ];
}

function replacePollResult(responseBody, pollRequest, rows) {
  const replies = Array.isArray(responseBody) ? responseBody : [responseBody];
  const reply = replies.find(
    (candidate) => String(candidate?.id) === String(pollRequest.id),
  );
  if (!reply)
    throw new Error(`poll JSON-RPC reply id not found: ${pollRequest.id}`);
  reply.result = [0, { log: rows }];
  return Array.isArray(responseBody) ? replies : reply;
}

function waitUntil(test, label, timeoutMs = 15000) {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const check = () => {
      if (test()) return resolve();
      if (Date.now() - started >= timeoutMs)
        return reject(new Error(`timed out waiting for ${label}`));
      setTimeout(check, 25);
    };
    check();
  });
}

function expectedArtifactHashes() {
	if (!existsSync(EXPECT_IPK))
		throw new Error(`final package artifact not found: ${EXPECT_IPK}`);
	const payload = spawnSync("tar", ["-xOf", EXPECT_IPK, "./data.tar.gz"], {
		maxBuffer: 64 * 1024 * 1024
	});
	if (payload.status !== 0)
		throw new Error(`cannot read package payload: ${payload.stderr}`);
	return new Map(RESOURCE_FILES.map(([relativePath, guestPath]) => {
		const file = spawnSync("tar", ["-xzOf", "-", `./www/luci-static/resources/${relativePath}`], {
			input: payload.stdout,
			maxBuffer: 32 * 1024 * 1024
		});
		if (file.status !== 0)
			throw new Error(`cannot read ${relativePath} from package: ${file.stderr}`);
		return [guestPath, createHash("sha256").update(file.stdout).digest("hex")];
	}));
}

function runReadOnlySshProbe() {
  if (process.env.FWLIVE_SKIP_SSH_PREFLIGHT === "1") {
    console.log("SSH preflight: SKIPPED by FWLIVE_SKIP_SSH_PREFLIGHT=1");
    return null;
  }

  const remote = [
    "set -eu",
    "cat /etc/openwrt_release",
    'if command -v opkg >/dev/null 2>&1; then opkg status luci-app-fwlive; elif command -v apk >/dev/null 2>&1; then apk info -a luci-app-fwlive; else echo "no supported package manager" >&2; exit 1; fi',
    "test -s /www/luci-static/resources/view/status/fwlive.js",
    "test -s /www/luci-static/resources/fwlive/table.js",
    "test -s /www/luci-static/resources/fwlive/chips.js",
    "sha256sum /www/luci-static/resources/view/status/fwlive.js /www/luci-static/resources/fwlive/table.js /www/luci-static/resources/fwlive/chips.js /www/luci-static/resources/fwlive/css.js",
    "ubus -S list | grep -E '^fwlive([.]|$)'",
  ].join("; ");
  const result = spawnSync(
    "ssh",
    [
      "-o",
      "BatchMode=yes",
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "UserKnownHostsFile=/dev/null",
      "-o",
      "LogLevel=ERROR",
      "-o",
      "ConnectTimeout=10",
      "-p",
      SSH_PORT,
      `${SSH_USER}@${HOST}`,
      remote,
    ],
    { encoding: "utf8", timeout: 20000 },
  );
  if (result.status !== 0) {
    const detail = (
      result.stderr ||
      result.stdout ||
      result.error?.message ||
      `ssh exit ${result.status}`
    ).trim();
    throw new Error(`read-only SSH preflight failed: ${detail}`);
  }
  const report = (result.stdout || "").trim();
  if (EXPECT_VERSION && !report.includes(EXPECT_VERSION))
    throw new Error(
      `installed package does not report expected version ${EXPECT_VERSION}:\n${report}`,
    );
  const installedHashes = new Map(
    report.split("\n").flatMap((line) => {
      const match = line.match(/^([a-f0-9]{64})\s+(.+)$/);
      return match ? [[match[2], match[1]]] : [];
    }),
  );
  const artifactHashes = expectedArtifactHashes();
  for (const [, guestPath] of RESOURCE_FILES) {
    const artifactHash = artifactHashes.get(guestPath);
    const installedHash = installedHashes.get(guestPath);
    if (installedHash !== artifactHash)
      throw new Error(
        `installed resource does not match final package artifact: ${guestPath} (artifact ${artifactHash || "missing"}, guest ${installedHash || "missing"})`,
      );
  }
  console.log(`Verified installed resources against package artifact ${EXPECT_IPK}`);
  console.log("Read-only installed guest identity/package/module hashes:");
  console.log(report);
  return report;
}

async function login(page) {
  await page.goto(VIEW_URL, { waitUntil: "domcontentloaded", timeout: 60000 });
  const username = page
    .locator('input[name="luci_username"], #luci_username')
    .first();
  if (await username.count()) {
    await username.fill(USERNAME);
    const password = page
      .locator('input[name="luci_password"], #luci_password')
      .first();
    if (await password.count()) await password.fill(PASSWORD);
    const submit = page.locator('button, input[type="submit"]').first();
    if (!(await submit.count()))
      throw new Error("LuCI login submit control is missing");
    await Promise.all([
      page
        .waitForNavigation({ waitUntil: "domcontentloaded", timeout: 30000 })
        .catch(() => {}),
      submit.click(),
    ]);
    await page.goto(VIEW_URL, {
      waitUntil: "domcontentloaded",
      timeout: 60000,
    });
  }
  await page.waitForSelector(".fwlive-map", { timeout: 30000 });
  await page.waitForSelector("#fwlive-table", { timeout: 30000 });
}

async function installPollFixtureRoute(page) {
  await page.route("**/ubus**", async (route) => {
    const requestCalls = parseCalls(route.request().postData() || "");
    const pollRequest = requestCalls.find(
      (call) => call.object === "fwlive" && call.method === "poll",
    );
    if (pollRequest) {
      calls.push({
        at: Date.now(),
        object: pollRequest.object,
        method: pollRequest.method,
      });
      pollRequestsInFlight++;
    }
    const stage = pollRequest ? activeFixtureStage : null;
    try {
      const response = await route.fetch();
      if (stage) {
        const body = await response.json();
        const fixture = fixtureRows(stage);
        const rewritten = replacePollResult(body, pollRequest, fixture);
        injected.push({
          stage,
          at: Date.now(),
          rowIds: fixture.map((row) => String(row.id)),
        });
        await route.fulfill({ response, body: JSON.stringify(rewritten) });
        return;
      }
      await route.fulfill({ response });
    } catch (error) {
      pageErrors.push(`route ${route.request().url()}: ${error.message}`);
      try {
        await route.abort();
      } catch {
        /* browser may have closed */
      }
    } finally {
      if (pollRequest) pollRequestsInFlight--;
    }
  });
}

async function triggerFreshPollWithLimit(page, stage) {
  const limit = page.locator("#fwlive-limit");
  if ((await limit.count()) !== 1)
    throw new Error("installed Limit control is missing");
  const values = await limit
    .locator("option")
    .evaluateAll((options) => options.map((option) => option.value));
  const current = await limit.inputValue();
  const alternate = values.find((value) => value !== current);
  if (!alternate)
    throw new Error("installed Limit control has no alternate value");
  const before = injected.length;
  activeFixtureStage = stage;
  await limit.selectOption(alternate);
  await waitUntil(
    () => injected.length > before && injected.at(-1).stage === stage,
    `${stage} controlled poll reply`,
    10000,
  );
  await waitUntil(
    () => pollRequestsInFlight === 0,
    `${stage} poll to settle`,
    10000,
  );
}

async function expansionButtonForRow(page, rowId, accessibleName) {
  const all = page.locator("button.fwlive-row-expand");
  const index = await all.evaluateAll(
    (buttons, id) =>
      buttons.findIndex((button) => String(button._fwliveRowId) === String(id)),
    rowId,
  );
  if (index < 0)
    throw new Error(`installed expansion button missing for row ${rowId}`);
  const button = all.nth(index);
  if ((await button.getAttribute("aria-label")) !== accessibleName)
    throw new Error(`row ${rowId} action name is not ${accessibleName}`);
  const byRole = page.getByRole("button", {
    name: accessibleName,
    exact: true,
  });
  const exposed = await byRole.evaluateAll(
    (buttons, id) =>
      buttons.some(
        (candidate) => String(candidate._fwliveRowId) === String(id),
      ),
    rowId,
  );
  if (!exposed)
    throw new Error(`row ${rowId} is not found by role/name ${accessibleName}`);
  return button;
}

async function rowForId(page, rowId) {
  const rows = page.locator("#fwlive-table tbody tr:not(.fwlive-msg-expand)");
  const index = await rows.evaluateAll(
    (elements, id) =>
      elements.findIndex(
        (element) => String(element._fwliveRowId) === String(id),
      ),
    rowId,
  );
  if (index < 0) throw new Error(`installed table row missing for id ${rowId}`);
  return rows.nth(index);
}

async function waitForInjectedRows(page) {
  await page.waitForFunction(
    (ids) => {
      const rows = Array.from(
        document.querySelectorAll(
          "#fwlive-table tbody tr:not(.fwlive-msg-expand)",
        ),
      );
      return ids.every((id) =>
        rows.some((row) => String(row._fwliveRowId) === id),
      );
    },
    [PASS_ROW_ID, DROP_ROW_ID],
    { timeout: 10000 },
  );
}

async function visibleRows(page) {
  return page
    .locator("#fwlive-table tbody tr:not(.fwlive-msg-expand)")
    .allInnerTexts();
}

async function waitForSingleActionRow(page, action) {
  await page.waitForFunction(
    (expectedAction) => {
      const rows = Array.from(
        document.querySelectorAll(
          "#fwlive-table tbody tr:not(.fwlive-msg-expand)",
        ),
      );
      return (
        rows.length === 1 &&
        rows[0].innerText.toLowerCase().includes(expectedAction)
      );
    },
    action,
    { timeout: 10000 },
  );
}

async function testChipAccessibleNames(page) {
  await page.evaluate(() => {
    window.__u2InstalledEvents = { invert: 0, expansion: 0 };
    document.addEventListener(
      "click",
      (event) => {
        const target =
          event.target instanceof Element
            ? event.target
            : event.target?.parentElement;
        if (!target) return;
        if (target.closest("button.fwlive-chip-invert"))
          window.__u2InstalledEvents.invert++;
        if (target.closest("button.fwlive-row-expand"))
          window.__u2InstalledEvents.expansion++;
      },
      true,
    );
  });
  const passLink = page
    .locator("#fwlive-table tbody a.fwlive-filter-link")
    .filter({ hasText: /^pass$/i })
    .first();
  await passLink.click();
  await page.waitForSelector(".fwlive-chip-invert", { timeout: 5000 });
  const linkExpansion = await page.evaluate(() => ({
    panels: document.querySelectorAll(
      "#fwlive-table tbody tr.fwlive-msg-expand",
    ).length,
    expanded: Array.from(
      document.querySelectorAll("#fwlive-table button.fwlive-row-expand"),
    ).some((button) => button.getAttribute("aria-expanded") === "true"),
  }));
  if (linkExpansion.panels || linkExpansion.expanded)
    throw new Error(
      `filter-link click also expanded a row: ${JSON.stringify(linkExpansion)}`,
    );
  const exclude = page.getByRole("button", {
    name: "Exclude instead",
    exact: true,
  });
  if ((await exclude.count()) !== 1)
    throw new Error("Include chip lacks Exclude instead accessible name");
  await exclude.press("Enter");
  await page.waitForFunction(() =>
    document.querySelector(".fwlive-chip-negated"),
  );
  await waitForSingleActionRow(page, "drop");
  let rows = await visibleRows(page);
  let events = await page.evaluate(() => window.__u2InstalledEvents.invert);
  if (events !== 1 || rows.length !== 1 || !/drop/i.test(rows[0]))
    throw new Error(
      `Enter did not exclude pass exactly once: events=${events}; rows=${JSON.stringify(rows)}`,
    );
  const include = page.getByRole("button", {
    name: "Include instead",
    exact: true,
  });
  if ((await include.count()) !== 1)
    throw new Error("excluded chip lacks Include instead accessible name");
  await include.press("Space");
  await page.waitForFunction(
    () => !document.querySelector(".fwlive-chip-negated"),
  );
  await waitForSingleActionRow(page, "pass");
  rows = await visibleRows(page);
  events = await page.evaluate(() => window.__u2InstalledEvents.invert);
  if (
    events !== 2 ||
    rows.length !== 1 ||
    !/pass/i.test(rows[0]) ||
    /drop/i.test(rows[0])
  )
    throw new Error(
      `Space did not include pass exactly once: events=${events}; rows=${JSON.stringify(rows)}`,
    );
  console.log(
    "Installed chip Include/Exclude role/name + Enter/Space one-click filter state: PASS",
  );
}


async function testOctoberControlsAndFocus(page) {
  const action = page.getByRole('combobox', { name: 'Filter by Action', exact: true });
  if (await action.count() !== 1) throw new Error('installed Action picker computed name missing');
  const remove = page.getByRole('link', { name: 'Remove filter', exact: true });
  if (await remove.count() !== 1) throw new Error('installed remove link computed name missing');
  await page.getByRole('button', { name: 'Exclude instead', exact: true }).focus();
  await page.evaluate(() => { window.__oct03Focused = document.activeElement; });
  for (const id of ['fwlive-msg-oneline', 'fwlive-msg-wrap', 'fwlive-msg-oneline', 'fwlive-msg-wrap']) {
    await page.locator('#' + id).evaluate(button => button.click());
    const retained = await page.evaluate(() => document.activeElement === window.__oct03Focused && window.__oct03Focused.isConnected);
    if (!retained) throw new Error('installed table paint replaced focused unchanged chip');
  }
  await page.getByRole('button', { name: 'Exclude instead', exact: true }).press('Enter');
  const sameControl = await page.evaluate(() => document.activeElement?.getAttribute('aria-label'));
  if (sameControl !== 'Include instead') throw new Error('polarity rebuild failed to follow focused invert');
  await page.getByRole('button', { name: 'Include instead', exact: true }).press('Space');
  await remove.press('Enter');
  if (await page.evaluate(() => document.activeElement?.id) !== 'fwlive-action') throw new Error('last removed chip failed associated filter focus fallback');
  await action.selectOption('pass');
  if (!(await page.locator('#fwlive-more-filters').evaluate(details => details.open)))
    await page.locator('#fwlive-more-filters > summary').click();
  await page.locator('#fwlive-src').fill('192.0.2.1');
  await page.locator('.fwlive-chip-remove[data-fwlive-chip-field="action"]').press('Enter');
  if (await page.evaluate(() => document.activeElement?.className) !== 'fwlive-chip-clear') throw new Error('removed chip failed surviving Clear all fallback');
  await page.getByRole('link', { name: 'Clear all', exact: true }).press('Enter');
  if (await page.evaluate(() => document.activeElement?.id) !== 'fwlive-q') throw new Error('Clear all failed search fallback');
  await action.selectOption('pass');
  await page.locator('#fwlive-q').focus();
  await page.locator('#fwlive-msg-oneline').evaluate(button => button.click());
  if (await page.evaluate(() => document.activeElement?.id) !== 'fwlive-q') throw new Error('paint stole outside focus');
  await page.locator('#fwlive-msg-wrap').evaluate(button => button.click());
  const geometry = await (await rowForId(page, PASS_ROW_ID)).evaluate(row => {
    const cell = row.querySelector('td');
    const button = cell?.querySelector('button.fwlive-row-expand');
    const c = cell?.getBoundingClientRect(), b = button?.getBoundingClientRect();
    return { cellWidth: c?.width, scrollWidth: cell?.scrollWidth, buttonRight: b?.right, cellRight: c?.right };
  });
  if (!geometry.cellWidth || geometry.buttonRight > geometry.cellRight + 1) throw new Error('installed Action button overflow: ' + JSON.stringify(geometry));
  console.log('Installed Action/remove computed names, unchanged-node paints, changed-chip/removed/Clear all focus, and Action geometry: PASS ' + JSON.stringify(geometry));
}

async function testExpansion(page) {
  await page.locator(".fwlive-chip-clear").click({ timeout: 5000 });
  await page.waitForFunction(
    () => document.querySelectorAll(".fwlive-chip-invert").length === 0,
    { timeout: 5000 },
  );
  await waitForInjectedRows(page);
  const row = await rowForId(page, PASS_ROW_ID);
  const rowId = await row.evaluate((element) => String(element._fwliveRowId));
  if (rowId !== PASS_ROW_ID)
    throw new Error(`unexpected pass fixture row id: ${rowId}`);
  const structure = await row.evaluate((element) => {
    const button = element.querySelector("button.fwlive-row-expand");
    return {
      tag: element.tagName,
      role: element.getAttribute("role"),
      tabindex: element.getAttribute("tabindex"),
      buttonTag: button?.tagName,
      buttonCell: button?.closest("td")?.tagName,
      label: button?.getAttribute("aria-label"),
      expanded: button?.getAttribute("aria-expanded"),
      controls: button?.getAttribute("aria-controls"),
      semanticRows: document.querySelectorAll("#fwlive-table tbody tr[role]")
        .length,
    };
  });
  if (
    structure.tag !== "TR" ||
    structure.role !== null ||
    structure.tabindex !== null ||
    structure.buttonTag !== "BUTTON" ||
    structure.buttonCell !== "TD" ||
    structure.label !== "Show full message" ||
    structure.expanded !== "false" ||
    structure.controls !== null ||
    structure.semanticRows !== 0
  )
    throw new Error(
      `installed table semantics/name failed: ${JSON.stringify(structure)}`,
    );

  const show = await expansionButtonForRow(page, PASS_ROW_ID, "Show full message");
  const actionLink = row
    .locator("a.fwlive-filter-link")
    .filter({ hasText: /^pass$/i })
    .first();
  await actionLink.focus();
  await page.keyboard.press("Tab");
  if (!(await show.evaluate((element) => element === document.activeElement)))
    throw new Error(
      "Tab from the row action filter link did not reach its message button",
    );

  let events = await page.evaluate(() => window.__u2InstalledEvents.expansion);
  await show.press("Enter");
  await page.waitForFunction(() =>
    document.querySelector("#fwlive-expanded-message"),
  );
  let hide = await expansionButtonForRow(page, PASS_ROW_ID, "Hide full message");
  events = await page.evaluate(() => window.__u2InstalledEvents.expansion);
  if (
    events !== 1 ||
    !(await hide.evaluate((element) => element === document.activeElement))
  )
    throw new Error(`Enter did not open/focus once: events=${events}`);
  const panel = await page.evaluate(() => {
    const button = document.activeElement;
    const panelId = button?.getAttribute("aria-controls");
    const body = panelId && document.getElementById(panelId);
    return {
      id: panelId,
      expanded: button?.getAttribute("aria-expanded"),
      bodyTag: body?.tagName,
      text: body?.textContent || "",
      images: body?.querySelectorAll("img").length ?? -1,
    };
  });
  if (
    panel.id !== "fwlive-expanded-message" ||
    panel.expanded !== "true" ||
    panel.bodyTag !== "PRE" ||
    !panel.text.includes("<img src=x onerror=alert(1)>") ||
    panel.images !== 0
  )
    throw new Error(
      `installed expanded message association/text failed: ${JSON.stringify(panel)}`,
    );
  console.log(
    "Installed expansion native table/button semantics, accessible state, and hostile text: PASS",
  );
  await page.screenshot({ path: SIMPLE_SCREENSHOT, fullPage: true });

  // Preserve the pre-existing mouse path on a non-link cell.
  let mouseRow = await rowForId(page, PASS_ROW_ID);
  await mouseRow.locator("td.fwlive-time").click();
  await page.waitForFunction(
    () => !document.querySelector("#fwlive-expanded-message"),
  );
  mouseRow = await rowForId(page, PASS_ROW_ID);
  await mouseRow.locator("td.fwlive-time").click();
  await page.waitForFunction(() =>
    document.querySelector("#fwlive-expanded-message"),
  );

  // Refocus the expanded native button and wait for an actual scheduled poll.
  // Its reply keeps the row ID and alters the message, forcing a keyed rebuild.
  hide = await expansionButtonForRow(page, PASS_ROW_ID, "Hide full message");
  await hide.focus();
  await page.evaluate((id) => {
    window.__u2OldExpansionButton = document.activeElement;
    if (String(window.__u2OldExpansionButton?._fwliveRowId) !== id)
      throw new Error("focused expander row identity mismatch before refresh");
  }, PASS_ROW_ID);
  const beforeRefreshInjection = injected.length;
  activeFixtureStage = "refresh";
  await waitUntil(
    () =>
      injected.length > beforeRefreshInjection &&
      injected.at(-1).stage === "refresh",
    "scheduled poll with the same already-seen row IDs",
    25000,
  );
  activeFixtureStage = null;
  await waitUntil(
    () => pollRequestsInFlight === 0,
    "scheduled duplicate-ID poll to settle",
    10000,
  );
  await page.waitForTimeout(100);
  hide = await expansionButtonForRow(page, PASS_ROW_ID, "Hide full message");
  await hide.focus();
  const duplicateIdMessage = await page
    .locator("#fwlive-expanded-message")
    .textContent();
  if (duplicateIdMessage?.includes("U2_REFRESHED_KEYED_ROW"))
    throw new Error("installed poll replaced an already-seen duplicate log ID");
  const beforeKeyedRebuild = await page.evaluate((id) => {
    window.__u2OldExpansionButton = document.activeElement;
    const row = document.activeElement?.closest("tr");
    window.__u2OldExpansionKey = row?._fwliveRowKey;
    if (String(window.__u2OldExpansionButton?._fwliveRowId) !== id)
      throw new Error("focused expander row identity mismatch before rebuild");
    return window.__u2OldExpansionKey;
  }, PASS_ROW_ID);
  if (typeof beforeKeyedRebuild !== "string")
    throw new Error("installed row render key is missing before rebuild");
  // The installed Message layout handler calls renderRows(true). Trigger its
  // click programmatically so the expanded native button remains active while
  // that handler synchronously replaces the same row under a changed render key.
  await page.locator("#fwlive-msg-oneline").evaluate((button) => button.click());
  await page.waitForFunction(
    (id) => {
      const focused = document.activeElement;
      const row = focused?.closest("tr");
      return (
        String(focused?._fwliveRowId) === id &&
        focused?.getAttribute("aria-label") === "Hide full message" &&
        row?._fwliveRowKey !== window.__u2OldExpansionKey
      );
    },
    PASS_ROW_ID,
    { timeout: 5000 },
  );
  const refresh = await page.evaluate((id) => ({
    oldConnected: window.__u2OldExpansionButton?.isConnected,
    sameNode: document.activeElement === window.__u2OldExpansionButton,
    oldKey: window.__u2OldExpansionKey,
    newKey: document.activeElement?.closest("tr")?._fwliveRowKey,
    focusedRowId: String(document.activeElement?._fwliveRowId),
    focusedName: document.activeElement?.getAttribute("aria-label"),
    focusedExpanded: document.activeElement?.getAttribute("aria-expanded"),
    panel:
      document.getElementById("fwlive-expanded-message")?.textContent || "",
    rowIdMatches: String(document.activeElement?._fwliveRowId) === id,
    layoutPressed: document
      .getElementById("fwlive-msg-oneline")
      ?.getAttribute("aria-pressed"),
  }), PASS_ROW_ID);
  if (
    refresh.oldConnected !== false ||
    refresh.sameNode ||
    !refresh.rowIdMatches ||
    refresh.oldKey === refresh.newKey ||
    refresh.focusedName !== "Hide full message" ||
    refresh.focusedExpanded !== "true" ||
    refresh.layoutPressed !== "true" ||
    !refresh.panel.includes("<img src=x onerror=alert(1)>")
  )
    throw new Error(
      `installed poll rebuild did not restore focus: ${JSON.stringify(refresh)}`,
    );
  console.log(
    "Installed scheduled duplicate-ID poll + renderRows(true) same-row keyed rebuild restores focused expander: PASS",
  );

  const refreshedHide = await expansionButtonForRow(
    page,
    PASS_ROW_ID,
    "Hide full message",
  );
  events = await page.evaluate(() => window.__u2InstalledEvents.expansion);
  await refreshedHide.press("Space");
  await page.waitForFunction(
    () => !document.querySelector("#fwlive-expanded-message"),
  );
  const afterSpace = await page.evaluate(
    () => window.__u2InstalledEvents.expansion,
  );
  if (afterSpace !== events + 1)
    throw new Error(
      `Space collapse did not click once: ${events} -> ${afterSpace}`,
    );
  const collapsed = await expansionButtonForRow(
    page,
    PASS_ROW_ID,
    "Show full message",
  );
  if (
    (await collapsed.getAttribute("aria-expanded")) !== "false" ||
    !(await collapsed.evaluate((element) => element === document.activeElement))
  )
    throw new Error(
      "Space did not collapse with the native button still focused",
    );

  const detail = page.locator("#fwlive-view-detail");
  await detail.click();
  await page.waitForFunction(
    () =>
      document
        .getElementById("fwlive-view-detail")
        ?.getAttribute("aria-pressed") === "true",
  );
  const detailState = await page.evaluate(() => ({
    buttons: document.querySelectorAll("#fwlive-table button.fwlive-row-expand")
      .length,
    panels: document.querySelectorAll("#fwlive-table tr.fwlive-msg-expand")
      .length,
    messageCells: document.querySelectorAll("#fwlive-table td.fwlive-message")
      .length,
    rows: document.querySelectorAll("#fwlive-table tbody tr").length,
  }));
  if (
    !detailState.rows ||
    detailState.buttons ||
    detailState.panels ||
    !detailState.messageCells
  )
    throw new Error(
      `Detail mode acquired Simple expansion: ${JSON.stringify(detailState)}`,
    );
  console.log(
    "Installed Detail view has no Simple expander and retains message cells: PASS",
  );
}

async function main() {
  const guestIdentity = runReadOnlySshProbe();
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
  });
  const page = await context.newPage();
  page.on("pageerror", (error) => pageErrors.push(error.message));
  try {
    await login(page);
    await installPollFixtureRoute(page);
    await triggerFreshPollWithLimit(page, "initial");
    await waitForInjectedRows(page);
    console.log(
      "Controlled /ubus HTTP poll fixture supplied two deterministic rows (not guest logd observations).",
    );
    await testChipAccessibleNames(page);
    await testOctoberControlsAndFocus(page);
    await testExpansion(page);
    await page.screenshot({ path: SCREENSHOT, fullPage: true });
    const relevantErrors = pageErrors.filter(
      (error) =>
        !/RPC call to uci\/get failed with error -32002: Access denied/.test(
          error,
        ),
    );
    if (relevantErrors.length)
      throw new Error(
        `browser/route errors: ${JSON.stringify(relevantErrors)}`,
      );
    console.log(
      JSON.stringify(
        {
          url: VIEW_URL,
          guestIdentity,
          injectedPolls: injected,
          observedPollCount: calls.length,
          pageErrors,
          screenshot: SCREENSHOT,
          simpleScreenshot: SIMPLE_SCREENSHOT,
        },
        null,
        2,
      ),
    );
  } finally {
    await context.close().catch(() => {});
    await browser.close().catch(() => {});
  }
}

main().catch((error) => {
  console.error(error.stack || error);
  console.error(
    JSON.stringify(
      { calls, injected, pollRequestsInFlight, pageErrors },
      null,
      2,
    ),
  );
  process.exitCode = 1;
});
