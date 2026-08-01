import assert from "node:assert/strict";
import { createServer } from "node:http";
import { access, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const option = (name, fallback = null) => {
  const index = process.argv.indexOf(name);
  if (index < 0) return fallback;
  assert.ok(process.argv[index + 1], `${name} requires a value`);
  return process.argv[index + 1];
};
const mode = option("--mode");
const fixtureRoot = option("--fixture-root");
const reportPath = path.resolve(option("--report"));
const playwrightPath = path.resolve(option("--playwright-module"));
const cdpUrl = option("--cdp-url", "http://127.0.0.1:9222");
const phase = option("--phase", "initial");
const packageFamily = option("--codex-package-family", "");
const scriptMarketRoot = path.resolve(option("--script-market-root"));
const nestedScripts = path.resolve(scriptMarketRoot, "scripts");
const scriptRoot = await access(nestedScripts)
  .then(() => nestedScripts, () => scriptMarketRoot);
const { chromium } = await import(pathToFileURL(playwrightPath).href);

async function poll(read, predicate, description, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  let value;
  do {
    value = await read();
    if (predicate(value)) return value;
    await new Promise((resolve) => setTimeout(resolve, 75));
  } while (Date.now() < deadline);
  assert.fail(`${description}; last value: ${JSON.stringify(value)}`);
}

function finiteDomText(text, description) {
  const values = String(text || "").match(/\d[\d,.]*/g) || [];
  assert.ok(values.length > 0, description);
  assert.ok(
    values.every((value) => Number.isFinite(Number(value.replaceAll(",", "")))),
    description,
  );
}

async function runtimeChecks(page, restartOnly = false) {
  await poll(
    () => page.evaluate(() => window.__codexContextMeter?.version),
    (value) => value === 101,
    "context meter v101 must be installed",
  );
  await poll(
    () => page.evaluate(() => window.__codexTokenUsageVersion),
    (value) => value === "0.1.7",
    "token usage v0.1.7 must be installed",
  );
  assert.equal(await page.locator("#codex-context-meter").isVisible(), true);
  if (restartOnly) {
    return { contextVersion: 101, tokenVersion: "0.1.7", enabledAfterRestart: true };
  }

  const contextReading = await poll(
    () => page.evaluate(() => window.__codexContextMeter?.getState?.().lastReading || null),
    (value) => Number.isFinite(value?.used) && Number.isFinite(value?.limit),
    "context meter initial reading must be finite",
  );
  finiteDomText(
    await page.locator("#codex-context-meter .ccm-value").textContent(),
    "context meter DOM must contain finite values",
  );
  const sendProviderUsage = (used, total = 1000) => page.evaluate(
    ({ used, total }) => {
      const remaining = total - used;
      window.dispatchEvent(new CustomEvent(
        "codex-context-meter-provider-summary",
        {
          detail: {
            providers: [{
              id: "monitor-smoke-provider",
              displayName: "Monitor Smoke",
              status: "active",
              used,
              total,
              usedPercent: used / total * 100,
              usedAmount: used,
              remainingAmount: remaining,
              totalAmount: total,
            }],
          },
        },
      ));
    },
    { used, total },
  );
  await sendProviderUsage(120);
  const initialProviderText = await poll(
    () => page.locator(
      "#codex-context-meter .ccm-provider-value",
    ).textContent(),
    (value) => Boolean(value) && !String(value).includes("--"),
    "context meter provider usage must render a finite initial value",
  );
  finiteDomText(
    initialProviderText,
    "context meter provider DOM must contain finite values",
  );

  const sendUsage = (id, total) => page.evaluate(
    ({ id, total }) => window.postMessage({
      id,
      usage: {
        input_tokens: Math.floor(total * 0.8),
        output_tokens: Math.ceil(total * 0.2),
        total_tokens: total,
      },
    }, "*"),
    { id, total },
  );
  const exportUsage = () => page.evaluate(() => window.__codexTokenUsage?.export?.() || null);
  await sendUsage("monitor-smoke-one", 100);
  const first = await poll(
    exportUsage,
    (value) => value?.ledgerEvents?.some((event) => event.eventId === "monitor-smoke-one"),
    "first usage must update token monitor",
  );
  await poll(
    () => page.locator(".codex-token-usage-badge").isVisible(),
    Boolean,
    "token usage badge must be visible",
  );
  finiteDomText(
    await page.locator(".codex-token-usage-badge").textContent(),
    "token usage badge must contain finite values",
  );
  const firstBadgeText =
    await page.locator(".codex-token-usage-badge").textContent();
  await sendUsage("monitor-smoke-two", 250);
  const second = await poll(
    exportUsage,
    (value) => value?.calls?.some((call) => call.eventId === "monitor-smoke-two"),
    "second usage must update token monitor",
  );
  assert.notDeepEqual(second.last?.usage, first.last?.usage, "second usage must change displayed usage");
  const secondBadgeText = await poll(
    () => page.locator(".codex-token-usage-badge").textContent(),
    (value) => Boolean(value) && value !== firstBadgeText,
    "token usage badge DOM must update after the second usage",
  );
  finiteDomText(secondBadgeText, "updated token badge DOM must stay finite");
  await sendProviderUsage(360);
  const changedProviderText = await poll(
    () => page.locator(
      "#codex-context-meter .ccm-provider-value",
    ).textContent(),
    (value) => Boolean(value) && value !== initialProviderText,
    "context meter provider DOM must update after the second usage",
  );
  finiteDomText(
    changedProviderText,
    "updated context meter provider DOM must stay finite",
  );
  const secondCallTotal = second.calls.reduce(
    (sum, call) => sum + Number(call.usage?.totalTokens || 0),
    0,
  );
  await sendUsage("monitor-smoke-two", 250);
  await new Promise((resolve) => setTimeout(resolve, 250));
  const duplicate = await exportUsage();
  assert.equal(
    duplicate.calls.filter((call) => call.eventId === "monitor-smoke-two").length,
    1,
    "duplicate response must not be accumulated",
  );
  assert.equal(
    duplicate.calls.reduce(
      (sum, call) => sum + Number(call.usage?.totalTokens || 0),
      0,
    ),
    secondCallTotal,
    "duplicate response must not increase the current-turn usage total",
  );

  const layout = await page.evaluate(() => {
    const selectors = {
      attachment: '[data-testid="attachment"]',
      send: '[data-testid="send"]',
      model: '[data-testid="model"]',
      window: '[data-testid^="window-"]',
    };
    const monitors = [
      document.querySelector("#codex-context-meter"),
      document.querySelector(".codex-token-usage-badge"),
    ].filter(Boolean).map((node) => node.getBoundingClientRect());
    const intersects = (a, b) =>
      Math.max(a.left, b.left) < Math.min(a.right, b.right)
      && Math.max(a.top, b.top) < Math.min(a.bottom, b.bottom);
    return Object.fromEntries(Object.entries(selectors).map(([name, selector]) => {
      const controls = [...document.querySelectorAll(selector)]
        .filter((node) => node.getClientRects().length > 0);
      return [name, {
        count: controls.length,
        covered: controls.some((node) =>
          monitors.some((monitor) => intersects(monitor, node.getBoundingClientRect()))),
      }];
    }));
  });
  for (const [name, result] of Object.entries(layout)) {
    assert.ok(result.count > 0, `${name} controls must exist`);
    assert.equal(result.covered, false, `${name} controls must not be covered`);
  }
  return {
    contextVersion: 101,
    tokenVersion: "0.1.7",
    initialFinite: true,
    usageUpdated: true,
    duplicateSuppressed: true,
    controlsUncovered: true,
    contextReading: {
      used: contextReading.used,
      limit: contextReading.limit,
      providerInitial: initialProviderText,
      providerUpdated: changedProviderText,
    },
  };
}

const manualRequired = [
  { check: "systemLogin", status: "manualRequired" },
  { check: "uac", status: "manualRequired" },
];

async function fixtureRun() {
  const resolvedFixture = path.resolve(fixtureRoot);
  const fixture = JSON.parse(
    await readFile(pathToFileURL(path.resolve(resolvedFixture, "fixture.json")), "utf8"),
  );
  const html = await readFile(
    pathToFileURL(path.resolve(resolvedFixture, "fake-renderer.html")),
  );
  const contextScript = await readFile(
    pathToFileURL(path.resolve(scriptRoot, "codex-context-used-meter.js")),
  );
  const tokenScript = await readFile(
    pathToFileURL(path.resolve(scriptRoot, "codex-token-usage.js")),
  );
  const server = createServer((request, response) => {
    const content = request.url === "/" ? html
      : request.url === "/codex-context-used-meter.js" ? contextScript
        : request.url === "/codex-token-usage.js" ? tokenScript : null;
    if (content) {
      response.writeHead(200, {
        "content-type": request.url === "/" ? "text/html; charset=utf-8"
          : "text/javascript; charset=utf-8",
      });
      response.end(content);
      return;
    }
    response.writeHead(404);
    response.end();
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const url = `http://127.0.0.1:${server.address().port}/`;
  let initial;
  let restart;
  try {
    const browser = await chromium.launch({ headless: true });
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    await page.addInitScript(() => {
      const NativeURL = window.URL;
      window.URL = class FixtureCodexUrl extends NativeURL {
        constructor(input, base) {
          if (String(input) === location.href) {
            return new NativeURL("app://-/index.html");
          }
          return new NativeURL(input, base);
        }
      };
    });
    await page.goto(url);
    await page.addScriptTag({ content: contextScript.toString("utf8") });
    await page.addScriptTag({ content: tokenScript.toString("utf8") });
    initial = await runtimeChecks(page);
    await browser.close();

    const restartedBrowser = await chromium.launch({ headless: true });
    const restartedPage = await restartedBrowser.newPage({ viewport: { width: 1280, height: 900 } });
    await restartedPage.addInitScript(() => {
      const NativeURL = window.URL;
      window.URL = class FixtureCodexUrl extends NativeURL {
        constructor(input, base) {
          if (String(input) === location.href) {
            return new NativeURL("app://-/index.html");
          }
          return new NativeURL(input, base);
        }
      };
    });
    await restartedPage.goto(url);
    await restartedPage.addScriptTag({ content: contextScript.toString("utf8") });
    await restartedPage.addScriptTag({ content: tokenScript.toString("utf8") });
    restart = await runtimeChecks(restartedPage, true);
    await restartedBrowser.close();
  } finally {
    await new Promise((resolve, reject) =>
      server.close((error) => error ? reject(error) : resolve()));
  }
  const report = {
    schemaVersion: 1,
    mode: "fixture",
    status: "pass",
    runtime: { status: "pass", checks: initial },
    persistence: { status: "pass", checks: restart },
    manualRequired,
  };
  const text = JSON.stringify(report, null, 2);
  assert.ok(!text.includes(fixture.fixtureSecret), "fixture secret must not appear in report");
  await writeFile(reportPath, `${text}\n`, "utf8");
}

async function connectRuntime() {
  let browser;
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      browser = await chromium.connectOverCDP(cdpUrl);
      break;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }
  assert.ok(browser, `could not connect to ${cdpUrl}`);
  const page = await poll(
    async () => browser.contexts().flatMap((context) => context.pages())
      .find((candidate) => candidate.url() !== "about:blank") || null,
    Boolean,
    "Codex renderer page must be available",
    30000,
  );
  const checks = await runtimeChecks(page, phase === "restart");
  let report = phase === "restart"
    ? JSON.parse(await readFile(reportPath, "utf8"))
    : {
        schemaVersion: 1,
        mode: "candidate",
        status: "inProgress",
        codexPackageFamily: packageFamily,
        manualRequired,
      };
  if (phase === "restart") {
    report.persistence = { status: "pass", checks };
    report.status = "pass";
  } else {
    report.runtime = { status: "pass", checks };
    report.persistence = { status: "pending" };
  }
  await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  await browser.close();
}

if (mode === "fixture") await fixtureRun();
else if (mode === "candidate") await connectRuntime();
else assert.fail("--mode must be fixture or candidate");
