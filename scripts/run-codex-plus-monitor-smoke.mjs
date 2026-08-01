#!/usr/bin/env node
import { createRequire } from "node:module";
import { access, lstat, mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import net from "node:net";
import path from "node:path";
import process from "node:process";
import { execFile, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const require = createRequire(import.meta.url);
const { chromium } = require("../tests/script-runtime/node_modules/playwright");
const execFileAsync = promisify(execFile);
const scriptNames = {
  contextMeter: "market-codex-context-used-meter.js",
  tokenUsage: "market-codex-token-usage.js",
};

function die(message) {
  throw new Error(message);
}

function parseArguments(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || !value || Object.hasOwn(options, key)) {
      die("usage: run-codex-plus-monitor-smoke.mjs --app /absolute/path/Codex++.app --home /absolute/path/isolated-home --report /absolute/path/monitor-smoke.json --screenshot /absolute/path/monitor-smoke.png");
    }
    options[key] = value;
  }
  for (const name of ["--app", "--home", "--report", "--screenshot"]) {
    if (!options[name] || !path.isAbsolute(options[name])) die(`${name} must be an absolute path`);
  }
  return {
    app: options["--app"],
    home: options["--home"],
    report: options["--report"],
    screenshot: options["--screenshot"],
  };
}

async function regularFile(file, executable = false) {
  const stat = await lstat(file).catch(() => null);
  if (!stat?.isFile() || stat.isSymbolicLink()) return false;
  if (executable) {
    await access(file, constants.X_OK).catch(() => die(`candidate launcher is not executable: ${file}`));
  }
  return true;
}

async function readVersion(file, expression) {
  const source = await readFile(file, "utf8");
  return source.match(expression)?.[1] ?? "unavailable";
}

export async function resolveCandidateLauncher(app) {
  const appStat = await lstat(app).catch(() => null);
  if (!appStat?.isDirectory() || appStat.isSymbolicLink()) {
    die(`candidate app is not a regular directory: ${app}`);
  }
  const canonicalApp = await realpath(app).catch(() => die(`candidate app cannot be resolved: ${app}`));
  const contents = path.join(app, "Contents");
  const contentsStat = await lstat(contents).catch(() => null);
  if (!contentsStat?.isDirectory() || contentsStat.isSymbolicLink()) {
    die(`candidate Contents is not a regular directory: ${contents}`);
  }
  const canonicalContents = await realpath(contents)
    .catch(() => die(`candidate Contents cannot be resolved: ${contents}`));
  if (path.dirname(canonicalContents) !== canonicalApp) {
    die(`candidate Contents escapes the app bundle: ${contents}`);
  }
  const macOS = path.join(contents, "MacOS");
  const macOSStat = await lstat(macOS).catch(() => null);
  if (!macOSStat?.isDirectory() || macOSStat.isSymbolicLink()) {
    die(`candidate MacOS is not a regular directory: ${macOS}`);
  }
  const canonicalMacOS = await realpath(macOS)
    .catch(() => die(`candidate MacOS cannot be resolved: ${macOS}`));
  if (path.dirname(canonicalMacOS) !== canonicalContents) {
    die(`candidate MacOS escapes Contents: ${macOS}`);
  }
  const infoPlist = path.join(contents, "Info.plist");
  if (!(await regularFile(infoPlist))) die(`candidate Info.plist is missing: ${infoPlist}`);
  let executable;
  try {
    ({ stdout: executable } = await execFileAsync(
      "/usr/bin/plutil",
      ["-extract", "CFBundleExecutable", "raw", "-expect", "string", "-n", "--", infoPlist],
      { encoding: "utf8", maxBuffer: 1024 },
    ));
  } catch {
    die(`candidate CFBundleExecutable is missing or invalid: ${infoPlist}`);
  }
  if (!executable ||
      executable.includes("/") ||
      executable.includes("..") ||
      /[\0\r\n]/u.test(executable) ||
      path.basename(executable) !== executable) {
    die(`candidate CFBundleExecutable is unsafe: ${infoPlist}`);
  }
  const launcher = path.join(app, "Contents", "MacOS", executable);
  if (!(await regularFile(launcher, true))) die(`candidate launcher is missing: ${launcher}`);
  const canonicalLauncher = await realpath(launcher)
    .catch(() => die(`candidate launcher cannot be resolved: ${launcher}`));
  if (path.dirname(canonicalLauncher) !== canonicalMacOS) {
    die(`candidate launcher escapes MacOS: ${launcher}`);
  }
  return launcher;
}

async function validateCandidate({ app, home }) {
  const homeStat = await lstat(home).catch(() => null);
  if (!homeStat?.isDirectory() || homeStat.isSymbolicLink()) die(`isolated home is not a regular directory: ${home}`);
  const launcher = await resolveCandidateLauncher(app);
  const scriptsDirectory = path.join(home, ".config", "Codex++", "user_scripts");
  const contextScript = path.join(scriptsDirectory, scriptNames.contextMeter);
  const tokenScript = path.join(scriptsDirectory, scriptNames.tokenUsage);
  if (!(await regularFile(contextScript))) die(`context meter script is missing: ${contextScript}`);
  if (!(await regularFile(tokenScript))) die(`token usage script is missing: ${tokenScript}`);
  const configurationPath = path.join(home, ".config", "Codex++", "user_scripts.json");
  let configuration;
  try {
    configuration = JSON.parse(await readFile(configurationPath, "utf8"));
  } catch {
    die(`script configuration is missing or invalid: ${configurationPath}`);
  }
  if (configuration?.enabled !== true ||
      configuration?.scripts?.[`user:${scriptNames.contextMeter}`] !== true ||
      configuration?.scripts?.[`user:${scriptNames.tokenUsage}`] !== true) {
    die("default monitor scripts are not enabled in the isolated Codex++ configuration");
  }
  return {
    launcher,
    scriptsDirectory,
    versions: {
      contextMeter: await readVersion(contextScript, /const\s+SCRIPT_VERSION\s*=\s*([0-9]+)\s*;/),
      tokenUsage: await readVersion(tokenScript, /const\s+SCRIPT_VERSION\s*=\s*["']([0-9.]+)["']\s*;/),
    },
  };
}

export function monitorSnapshot() {
  const safeNumber = (value) => {
    const number = Number(value);
    return Number.isFinite(number) ? String(number) : "unavailable";
  };
  const visible = (element) => {
    if (!element) return false;
    const style = getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return style.visibility !== "hidden" && style.display !== "none" && rect.width > 0 && rect.height > 0;
  };
  const contextRoot = document.querySelector("#codex-context-meter");
  const tokenRoot = document.querySelector(".codex-token-usage-badge");
  const contextReading = window.__codexContextMeter?.getState?.()?.lastReading;
  const tokenMetric = window.__codexTokenUsage?.last?.usage;
  return {
    contextMeter: {
      visible: visible(contextRoot),
      version: String(window.__codexContextMeter?.version ?? "unavailable"),
      value: safeNumber(contextReading?.used ?? contextReading?.usedTokens ?? contextReading?.used_tokens),
    },
    tokenUsage: {
      visible: visible(tokenRoot),
      version: String(window.__codexTokenUsageVersion ?? window.__codexTokenUsage?.version ?? "unavailable"),
      value: safeNumber(tokenMetric?.totalTokens),
    },
  };
}

async function unusedPort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => server.once("error", reject).listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  return port;
}

function launcherEnvironment(home) {
  return {
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
    LANG: "en_US.UTF-8",
    HOME: home,
    CFFIXED_USER_HOME: home,
    CODEX_HOME: path.join(home, ".codex"),
    XDG_CONFIG_HOME: path.join(home, ".config"),
    TMPDIR: path.join(home, "tmp"),
  };
}

function startLauncher(launcher, home, port) {
  const child = spawn(launcher, ["--debug-port", String(port)], {
    cwd: path.dirname(launcher),
    detached: true,
    stdio: "ignore",
    env: launcherEnvironment(home),
  });
  child.unref();
  return child;
}

function stopLauncher(child) {
  if (!child?.pid) return;
  try { process.kill(-child.pid, "SIGTERM"); } catch {}
}

async function connectToPage(port, timeoutMs = 12000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const browser = await chromium.connectOverCDP(`http://127.0.0.1:${port}`);
      const page = browser.contexts().flatMap((context) => context.pages())
        .find((candidate) => !candidate.url().startsWith("devtools://"));
      if (page) return { browser, page };
      await browser.close();
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw lastError ?? new Error("Codex render page did not become available");
}

async function injectUsage(page, responseId, contextUsed) {
  await page.evaluate(async ({ responseId, contextUsed }) => {
    const conversationId = `monitor-smoke-${responseId}`;
    let anchor = document.querySelector("[data-codex-monitor-smoke-anchor]");
    if (!anchor) {
      anchor = document.createElement("div");
      anchor.dataset.codexMonitorSmokeAnchor = "true";
      anchor.style.display = "none";
      document.body.append(anchor);
    }
    anchor.setAttribute("aria-current", "page");
    anchor.setAttribute("data-app-action-sidebar-thread-id", conversationId);
    window.__codexMonitorSmokeContext = { conversationId, usedTokens: contextUsed, contextWindow: 1000 };
    window.dispatchEvent(new CustomEvent("codex-context-meter-provider-summary", {
      detail: {
        providers: [{
          id: "monitor-smoke",
          displayName: "Monitor smoke",
          status: "active",
          used: contextUsed,
          total: 1000,
          usedAmount: contextUsed / 10,
          remainingAmount: 100 - contextUsed / 10,
          totalAmount: 100,
          usedPercent: contextUsed / 10,
        }],
      },
    }));
    await fetch(`https://codex-monitor-smoke.invalid/v1/responses/${responseId}`);
  }, { responseId, contextUsed });
  await page.waitForTimeout(650);
  await page.evaluate(() => window.__codexContextMeter?.refresh?.());
  await page.waitForTimeout(250);
}

async function scriptsStillEnabled(home) {
  try {
    const config = JSON.parse(await readFile(path.join(home, ".config", "Codex++", "user_scripts.json"), "utf8"));
    return config?.enabled === true &&
      config?.scripts?.[`user:${scriptNames.contextMeter}`] === true &&
      config?.scripts?.[`user:${scriptNames.tokenUsage}`] === true;
  } catch {
    return false;
  }
}

function manualReport(versions, reason, persistence) {
  return {
    schemaVersion: 1,
    status: "manual_required",
    manualRequired: true,
    reason,
    contextMeter: { visible: false, version: versions.contextMeter, before: "unavailable", after: "unavailable" },
    tokenUsage: { visible: false, version: versions.tokenUsage, before: "unavailable", after: "unavailable" },
    restartPersistence: persistence,
    screenshotCaptured: false,
  };
}

export function assertSafeReport(report) {
  const serialized = JSON.stringify(report);
  const sensitive = /\bsk-[A-Za-z0-9_-]+\b|\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b|device[\s_-]*code|chat[\s_-]*body/i;
  if (sensitive.test(serialized)) die("report contains sensitive data");
}

async function writeReport(reportPath, report) {
  assertSafeReport(report);
  await mkdir(path.dirname(reportPath), { recursive: true, mode: 0o700 });
  await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const candidate = await validateCandidate(options);
  await mkdir(path.join(options.home, ".codex"), { recursive: true, mode: 0o700 });
  await mkdir(path.join(options.home, ".config"), { recursive: true, mode: 0o700 });
  await mkdir(path.join(options.home, "tmp"), { recursive: true, mode: 0o700 });
  let firstLauncher;
  let secondLauncher;
  let browser;
  let report;
  let renderConnected = false;
  try {
    const port = await unusedPort();
    firstLauncher = startLauncher(candidate.launcher, options.home, port);
    const connected = await connectToPage(port);
    renderConnected = true;
    browser = connected.browser;
    const { page } = connected;
    await page.route("**://codex-monitor-smoke.invalid/**", async (route) => {
      const second = route.request().url().includes("monitor-smoke-second");
      const totalTokens = second ? 300 : 150;
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        headers: { "access-control-allow-origin": "*" },
        body: JSON.stringify({ id: second ? "monitor-smoke-second" : "monitor-smoke-first", usage: { input_tokens: totalTokens - 20, output_tokens: 20, total_tokens: totalTokens } }),
      });
    });
    await injectUsage(page, "monitor-smoke-first", 100);
    const before = await page.evaluate(monitorSnapshot);
    await injectUsage(page, "monitor-smoke-second", 200);
    const after = await page.evaluate(monitorSnapshot);
    const updated = before.contextMeter.value !== after.contextMeter.value && before.tokenUsage.value !== after.tokenUsage.value;
    const bothVisible = before.contextMeter.visible && before.tokenUsage.visible && after.contextMeter.visible && after.tokenUsage.visible;
    const versionsMatch = before.contextMeter.version === candidate.versions.contextMeter && before.tokenUsage.version === candidate.versions.tokenUsage;
    await page.screenshot({ path: options.screenshot });
    await browser.close();
    browser = undefined;
    stopLauncher(firstLauncher);
    firstLauncher = undefined;

    const restartPort = await unusedPort();
    secondLauncher = startLauncher(candidate.launcher, options.home, restartPort);
    const restarted = await connectToPage(restartPort);
    const restartSnapshot = await restarted.page.evaluate(monitorSnapshot);
    await restarted.browser.close();
    const persistence = {
      contextMeter: (await scriptsStillEnabled(options.home)) && restartSnapshot.contextMeter.visible,
      tokenUsage: (await scriptsStillEnabled(options.home)) && restartSnapshot.tokenUsage.visible,
    };
    report = {
      schemaVersion: 1,
      status: bothVisible && updated && versionsMatch && persistence.contextMeter && persistence.tokenUsage ? "pass" : "fail",
      manualRequired: false,
      contextMeter: { visible: bothVisible && after.contextMeter.visible, version: after.contextMeter.version, before: before.contextMeter.value, after: after.contextMeter.value },
      tokenUsage: { visible: bothVisible && after.tokenUsage.visible, version: after.tokenUsage.version, before: before.tokenUsage.value, after: after.tokenUsage.value },
      restartPersistence: persistence,
      screenshotCaptured: true,
    };
  } catch {
    const persistence = { contextMeter: await scriptsStillEnabled(options.home), tokenUsage: await scriptsStillEnabled(options.home) };
    report = renderConnected
      ? {
          schemaVersion: 1,
          status: "fail",
          manualRequired: false,
          contextMeter: { visible: false, version: candidate.versions.contextMeter, before: "unavailable", after: "unavailable" },
          tokenUsage: { visible: false, version: candidate.versions.tokenUsage, before: "unavailable", after: "unavailable" },
          restartPersistence: persistence,
          screenshotCaptured: false,
        }
      : manualReport(candidate.versions, "real_render_page_unavailable", persistence);
  } finally {
    if (browser) await browser.close().catch(() => {});
    stopLauncher(firstLauncher);
    stopLauncher(secondLauncher);
  }
  await writeReport(options.report, report);
  if (report.status === "fail") die("Codex++ monitor components were not visible, updated, and persistent");
  process.stdout.write(`${options.report}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`run-codex-plus-monitor-smoke: ${error.message}\n`);
    process.exitCode = 1;
  });
}
