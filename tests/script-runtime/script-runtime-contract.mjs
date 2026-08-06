import assert from "node:assert/strict";
import { createServer } from "node:http";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import { chromium } from "playwright";

const here = path.dirname(fileURLToPath(import.meta.url));
const argument = (name) => {
  const index = process.argv.indexOf(name);
  if (index < 0) return null;
  assert.ok(process.argv[index + 1], `${name} requires a value`);
  return process.argv[index + 1];
};
const requestedScriptMarket = argument("--script-market-root");
const scriptMarketRoot = path.resolve(
  process.cwd(),
  requestedScriptMarket || path.resolve(here, "../../Resources/script-market-sources"),
);
const nestedScripts = path.resolve(scriptMarketRoot, "scripts");
const scriptDirectory = await access(nestedScripts).then(() => nestedScripts, () => scriptMarketRoot);
const shellUrl = pathToFileURL(path.resolve(here, "codex-shell.html"));
const contextMeterUrl = pathToFileURL(path.resolve(scriptDirectory, "codex-context-used-meter.js"));
const tokenUsageUrl = pathToFileURL(path.resolve(scriptDirectory, "codex-token-usage.js"));
const shell = await readFile(shellUrl);
const contextMeter = await readFile(contextMeterUrl, "utf8");
const tokenUsage = await readFile(tokenUsageUrl, "utf8");

async function poll(read, expected, description, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  let actual;
  do {
    actual = await read();
    if (actual === expected) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  } while (Date.now() < deadline);
  assert.equal(actual, expected, description);
}

function assertFiniteDomNumber(text, description) {
  const values = String(text || "").match(/\d[\d,.]*/g) || [];
  assert.ok(values.length, description);
  values.forEach((value) => assert.ok(Number.isFinite(Number(value.replaceAll(",", ""))), description));
}

const server = createServer((request, response) => {
  if (request.url === "/index.html") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(shell);
    return;
  }
  const payloads = {
    "/v1/responses": { id: "response-one", usage: { input_tokens: 120, output_tokens: 30, total_tokens: 150 } },
    "/v1/chat/completions": { id: "deepseek-one", usage: { prompt_tokens: 200, completion_tokens: 100, total_tokens: 300 } },
    "/v1/chat/completions/kimi-stream": "data: {\"id\":\"kimi-one\",\"usage\":{\"input_tokens\":300,\"output_tokens\":150,\"total_tokens\":450}}\n\ndata: [DONE]\n\n",
    "/v1/responses-thread-two": { id: "response-two", usage: { input_tokens: 80, output_tokens: 20, total_tokens: 100 } },
  };
  if (Object.hasOwn(payloads, request.url)) {
    response.writeHead(200, { "content-type": typeof payloads[request.url] === "string" ? "text/event-stream" : "application/json" });
    response.end(typeof payloads[request.url] === "string" ? payloads[request.url] : JSON.stringify(payloads[request.url]));
    return;
  }
  response.writeHead(404);
  response.end();
});

await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const address = server.address();
const baseUrl = `http://127.0.0.1:${address.port}`;
const browser = await chromium.launch({ headless: true });
const screenshotDirectory = await mkdtemp(path.join(tmpdir(), "codex-script-runtime-"));

try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const requests = [];
  page.on("request", (request) => requests.push(request.url()));
  await page.addInitScript(() => {
    const NativeURL = window.URL;
    window.URL = class TestCodexUrl extends NativeURL {
      constructor(input, base) {
        if (String(input) === location.href) return new NativeURL("app://-/index.html");
        return new NativeURL(input, base);
      }
    };
  });
  await page.goto(`${baseUrl}/index.html`);
  await page.addScriptTag({ content: contextMeter });
  await page.addScriptTag({ content: tokenUsage });

  await poll(() => page.evaluate(() => window.__codexContextMeter?.version), 101, "context meter should install");
  await poll(() => page.evaluate(() => window.__codexTokenUsageVersion), "0.1.7", "token usage script should install");
  assert.equal(
    await page.locator("#codex-context-meter").isVisible(),
    true,
    "context meter should be visible when the Codex shell exposes usage",
  );

  await poll(
    () => page.evaluate(() => Number.isFinite(window.__codexContextMeter?.getState?.().lastReading?.used)),
    true,
    "context meter should read the fixture's structured usage signal",
  );
  const contextText = await page.locator("#codex-context-meter .ccm-value").textContent();
  assertFiniteDomNumber(contextText, "context meter DOM text should contain finite numeric values");

  await page.evaluate(() => fetch("/v1/responses"));
  await poll(
    () => page.evaluate(() => window.__codexTokenUsageScriptTest?.getDisplayMetric?.()?.usage?.totalTokens),
    150,
    "OpenAI Responses usage should render",
  );
  await poll(() => page.locator(".codex-token-usage-badge").isVisible(), true, "token badge should be visible");
  await poll(
    async () => /本轮调用合计\s+150(?:\D|$)/.test(
      (await page.locator(".codex-token-usage-badge").textContent()) || "",
    ),
    true,
    "token badge DOM text should render the OpenAI total of 150",
  );
  const tokenText = await page.locator(".codex-token-usage-badge").textContent();
  assertFiniteDomNumber(tokenText, "token badge DOM text should contain finite numeric values");
  assert.match(tokenText || "", /本轮调用合计\s+150(?:\D|$)/, "token badge DOM text should render the OpenAI total of 150");

  await page.evaluate(async () => {
    await fetch("/v1/responses");
    await new Promise((resolve) => setTimeout(resolve, 200));
  });
  await poll(
    () => page.evaluate(() => window.__codexTokenUsageDebug.filter((entry) => entry.url.endsWith("/v1/responses")).length >= 2),
    true,
    "the repeated OpenAI Responses payload should traverse the network observer",
  );
  const duplicateResponse = await page.evaluate(() => {
    const metric = window.__codexTokenUsageScriptTest.getDisplayMetric();
    return {
      callsWithResponseId: metric.calls.filter((call) => call.eventId === "response-one").length,
      totalTokens: metric.usage.totalTokens,
    };
  });
  assert.equal(duplicateResponse.callsWithResponseId, 1, "a repeated provider response ID must not be counted twice");
  assert.equal(duplicateResponse.totalTokens, 150, "a repeated provider response must not increase the displayed total");

  const beforeDeepSeek = await page.evaluate(() => window.__codexTokenUsageScriptTest.getDisplayMetric().usage.totalTokens);
  await page.evaluate(() => fetch("/v1/chat/completions"));
  await poll(
    () => page.evaluate(() => window.__codexTokenUsageScriptTest?.getDisplayMetric?.()?.usage?.totalTokens),
    beforeDeepSeek + 300,
    "DeepSeek Chat Completions usage should update the current turn metric",
  );
  const beforeKimi = await page.evaluate(() => window.__codexTokenUsageScriptTest.getDisplayMetric().usage.totalTokens);
  await page.evaluate(() => fetch("/v1/chat/completions/kimi-stream"));
  await poll(
    () => page.evaluate(() => window.__codexTokenUsageScriptTest?.getDisplayMetric?.()?.usage?.totalTokens),
    beforeKimi + 450,
    "Kimi's final streaming usage should render",
  );

  await page.evaluate(() => {
    window.__codexRuntimeFixture.setConversation("thread-two", 6000);
    window.__codexTokenUsageScriptTest.setActiveConversationId("thread-two");
    window.__codexContextMeter.refresh();
  });
  await poll(
    () => page.evaluate(() => window.__codexContextMeter?.getState?.().lastReading?.conversationId),
    "thread-two",
    "context meter should switch to the new conversation",
  );
  await page.evaluate(() => fetch("/v1/responses-thread-two"));
  await poll(
    () => page.evaluate(() => window.__codexTokenUsageScriptTest?.getDisplayMetric?.()?.conversationId),
    "thread-two",
    "token meter should not retain the previous conversation",
  );
  await poll(
    () => page.evaluate(() => window.__codexTokenUsageScriptTest?.getDisplayMetric?.()?.usage?.totalTokens),
    100,
    "the new conversation must not accumulate the previous conversation's usage",
  );

  for (const width of [800, 1280]) {
    await page.setViewportSize({ width, height: 900 });
    for (const theme of ["light", "dark"]) {
      await page.evaluate((theme) => {
        localStorage.setItem("__codexContextMeterUiState", JSON.stringify({ mode: "inline", theme, x: 16, y: 10, scale: 1 }));
        window.__codexContextMeter.destroy();
      }, theme);
      await page.addScriptTag({ content: contextMeter });
      await poll(() => page.evaluate(() => document.querySelector("#codex-context-meter")?.dataset.theme), theme, `meter should apply ${theme} mode`);
      const overlaps = await page.evaluate(() => {
        const intersect = (a, b) => Math.max(a.left, b.left) < Math.min(a.right, b.right) && Math.max(a.top, b.top) < Math.min(a.bottom, b.bottom);
        const meter = document.querySelector("#codex-context-meter").getBoundingClientRect();
        return ["attachment", "send", "model"].filter((name) => intersect(meter, document.querySelector(`[data-testid="${name}"]`).getBoundingClientRect()));
      });
      assert.deepEqual(overlaps, [], `meter must not overlap composer controls at ${width}px in ${theme} mode`);
    }
  }

  const wrappedFetch = await page.evaluate(() => {
    const before = window.fetch;
    window.__codexContextMeter.destroy();
    return { beforeWrapped: before.__codexTokenUsageWrapped, rootCount: document.querySelectorAll("#codex-context-meter").length };
  });
  assert.equal(wrappedFetch.rootCount, 0, "destroy should remove the context meter");
  await page.addScriptTag({ content: contextMeter });
  await page.addScriptTag({ content: tokenUsage });
  const reloaded = await page.evaluate(() => ({
    rootCount: document.querySelectorAll("#codex-context-meter").length,
    fetchWrapped: window.fetch.__codexTokenUsageWrapped,
  }));
  assert.equal(reloaded.rootCount, 1, "reload must leave exactly one context meter root");
  assert.equal(reloaded.fetchWrapped, wrappedFetch.beforeWrapped, "reload must not nest the network interceptor");
  assert.ok(requests.every((url) => new URL(url).origin === baseUrl), "the scripts must not request an external domain");
  await page.screenshot({ path: path.join(screenshotDirectory, "contract.png") });

  console.log("script-runtime-contract: PASS");
} finally {
  await browser.close();
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  await rm(screenshotDirectory, { recursive: true, force: true });
}
