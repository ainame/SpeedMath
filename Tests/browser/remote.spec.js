import { test, expect } from "@playwright/test";
import jsQR from "jsqr";
import { PNG } from "pngjs";

// Pairing starts from the child's home screen (the header's リモコン button).
async function presenter(page) {
  await page.goto("/#/");
  await page.locator(".header-remote").getByRole("button", { name: "リモコン" }).click();
  await expect(page.locator(".pair-qr")).toBeVisible();
}

async function decodeQR(page) {
  const png = PNG.sync.read(await page.locator(".pair-qr").screenshot());
  const decoded = jsQR(new Uint8ClampedArray(png.data), png.width, png.height);
  expect(decoded?.data).toContain("/#/remote?invite=");
  return decoded.data;
}

async function codeJoin(page, remote) {
  const code = await page.locator(".pair-code").textContent();
  await remote.goto("/#/remote");
  await remote.getByRole("textbox", { name: "コード" }).fill(code.toLowerCase().replaceAll("-", " "));
  await remote.getByRole("button", { name: "コードで つなぐ" }).click();
}

async function approve(page, remote) {
  await expect(remote.getByText("しょうにんを まっています")).toBeVisible();
  await expect(remote.getByRole("button", { name: "スタート！" })).toHaveCount(0);
  await expect(page.locator(".pair-code")).toHaveText(await remote.locator(".pair-code").textContent());
  await page.getByRole("button", { name: "つなぐ", exact: true }).click();
  // The panel closes by itself; the child's home shows the indicator and locks the choices.
  await expect(page.locator(".pair-panel")).toHaveCount(0);
  await expect(page.locator(".header-remote")).toHaveText("リモコン ✓");
  await expect(page.getByText("リモコンで えらんでね")).toBeVisible();
  await expect(page.getByRole("link", { name: "スタート！" })).toHaveCount(0);
  await expect(remote.getByRole("button", { name: "スタート！" })).toBeEnabled();
}

// A three-card game for short tests: the child's own URL, changed in place so the pairing stays.
async function shortGame(page, remote) {
  await page.evaluate(() => { location.hash = "#/play/add?count=3"; });
  await expect(remote.getByRole("button", { name: "はじめる" })).toBeEnabled();
}

test("the parent chooses, starts, plays and picks what comes next; one record and stamp", async ({ page, browser }) => {
  const remoteContext = await browser.newContext();
  const remote = await remoteContext.newPage();
  let dropped = 0;
  await remote.routeWebSocket("**/api/socket/**", ws => {
    const server = ws.connectToServer();
    server.onMessage(text => {
      if (JSON.parse(text).type === "ack" && !dropped) { dropped++; return; }
      ws.send(text);
    });
  });
  try {
    await presenter(page);
    await codeJoin(page, remote);
    await approve(page, remote);
    expect(dropped).toBe(0);

    // Settings chosen on the Remote show on the child's locked home screen.
    await remote.locator(".remote-deck", { hasText: "くりさがり なし" }).click();
    await expect(page.locator(".deck.selected")).toContainText("くりさがり なし");
    await expect(page.locator(".deck.selected")).toBeDisabled();
    await remote.getByRole("button", { name: "かくす" }).click();
    await expect(page.locator(".chip.selected", { hasText: "かくす" })).toBeVisible();
    expect(dropped).toBe(1); // the first command's ACK was lost and the resend was answered

    // スタート！ moves the child to はじめる; the child has no start button while paired.
    await remote.getByRole("button", { name: "スタート！" }).click();
    await expect(page.getByText("ひきざん（くりさがり なし）")).toBeVisible();
    await expect(page.getByText("リモコンで はじめてね")).toBeVisible();
    await expect(page.getByRole("button", { name: "はじめる" })).toHaveCount(0);
    await remote.getByRole("button", { name: "えらびなおす" }).click();
    await expect(page.getByText("1. カードを えらぼう")).toBeVisible();

    await shortGame(page, remote);
    await remote.getByRole("button", { name: "はじめる" }).click();
    await expect(page.locator(".countdown-number")).toHaveText("3");
    await expect(remote.locator(".remote-answer")).toHaveCount(0);
    await expect(page.locator(".progress-count")).toHaveText("1 / 3");
    await expect(page.getByRole("link", { name: "✕ やめる" })).toHaveCount(0);
    await expect(remote.locator(".remote-count")).toHaveText("1 / 3");
    await expect(remote.locator(".remote-answer")).toHaveText(/こたえ\s*\d+/);
    await expect(page.getByText("こたえ", { exact: false })).toHaveCount(0);
    await remote.getByRole("button", { name: "つぎ" }).click();
    await expect(page.locator(".progress-count")).toHaveText("2 / 3");
    // The child can still tap through the cards.
    await page.locator(".tap-previous").click();
    await expect(remote.locator(".remote-count")).toHaveText("1 / 3");

    await remoteContext.setOffline(true);
    await expect(remote.getByRole("button", { name: "つぎ" })).toBeDisabled();
    await page.keyboard.press("ArrowRight");
    await expect(page.locator(".progress-count")).toHaveText("2 / 3");
    await remoteContext.setOffline(false);
    await expect(remote.locator(".remote-count")).toHaveText("2 / 3");
    await expect(remote.getByRole("button", { name: "つぎ" })).toBeEnabled();
    for (let i = 0; i < 2; i++) await remote.getByRole("button", { name: "つぎ" }).click();
    await expect(page.getByText("おわり！", { exact: true })).toBeVisible();
    await expect(remote.getByText("おわり！", { exact: true })).toBeVisible();
    await expect(page.getByText("リモコンで つぎを えらんでね")).toBeVisible();
    await expect(page.getByRole("button", { name: "もういちど" })).toHaveCount(0);

    await remote.getByRole("button", { name: "もういちど" }).click();
    await expect(page.getByText("リモコンで はじめてね")).toBeVisible();
    await remote.getByRole("button", { name: "えらびなおす" }).click();
    await expect(page.getByText("1. カードを えらぼう")).toBeVisible();
    await expect(page.locator(".header-remote")).toHaveText("リモコン ✓");

    await page.goto("/#/records");
    await expect(page.locator(".record-row")).toHaveCount(1);
    await page.goto("/#/stamps");
    await expect(page.locator(".stamp-slot-image")).toHaveCount(1);
  } finally { await remoteContext.close(); }
});

test("decode the displayed QR, strip invite, reload the Presenter mid-game, and unpair", async ({ page, browser }) => {
  const context = await browser.newContext();
  const remote = await context.newPage();
  try {
    await presenter(page);
    await remote.goto(await decodeQR(page));
    await approve(page, remote);
    await expect(remote).toHaveURL(/#\/remote$/);
    await shortGame(page, remote);
    await remote.getByRole("button", { name: "はじめる" }).click();
    await remote.getByRole("button", { name: "つぎ" }).click();
    await expect(page.locator(".progress-count")).toHaveText("2 / 3");
    // A reload keeps the pairing; the play screen starts over at はじめる.
    await page.reload();
    await expect(remote.getByRole("button", { name: "はじめる" })).toBeEnabled();
    await remote.getByRole("button", { name: "えらびなおす" }).click();
    await expect(page.getByText("1. カードを えらぼう")).toBeVisible();
    // The indicator on the home screen offers to end the pairing.
    await page.locator(".header-remote").getByRole("button", { name: "リモコン ✓" }).click();
    await page.getByRole("button", { name: "リモコンを はずす" }).click();
    await expect(remote.getByRole("textbox", { name: "コード" })).toBeVisible();
    await expect(page.locator(".header-remote")).toHaveText("リモコン");
    await expect(page.getByRole("link", { name: "スタート！" })).toBeVisible();
  } finally { await context.close(); }
});

test("a QR scanned into an already open Remote tab joins without reloading", async ({ page, browser }) => {
  const context = await browser.newContext();
  const remote = await context.newPage();
  try {
    await presenter(page);
    const link = new URL(await decodeQR(page));
    // The Remote tab is open on the code form with a half-typed code, as when iOS reuses a tab.
    await remote.goto("/#/remote");
    await remote.getByRole("textbox", { name: "コード" }).fill("ABCD");
    await remote.evaluate(() => { window.sameDocument = true; });
    await remote.evaluate(hash => { location.hash = hash; }, link.hash);
    await approve(page, remote);
    expect(await remote.evaluate(() => window.sameDocument)).toBe(true);
    await expect(remote).toHaveURL(/#\/remote$/);

    // Unpair, then pair again from another screen of the Remote's app with a fresh code.
    await page.locator(".header-remote").getByRole("button", { name: "リモコン ✓" }).click();
    await page.getByRole("button", { name: "リモコンを はずす" }).click();
    await page.getByRole("button", { name: "コードを だす" }).click();
    const link2 = new URL(await decodeQR(page));
    await remote.evaluate(() => { location.hash = "#/"; });
    await expect(remote.getByText("1. カードを えらぼう")).toBeVisible();
    await remote.evaluate(hash => { location.hash = hash; }, link2.hash);
    await approve(page, remote);
    expect(await remote.evaluate(() => window.sameDocument)).toBe(true);
  } finally { await context.close(); }
});

for (const [width, height] of [[812, 375], [667, 320], [375, 812], [1280, 800]]) {
  test(`local play, safe area and layout at ${width}×${height}`, async ({ page }) => {
    await page.setViewportSize({ width, height });
    await page.goto("/#/play/sub?count=3&timer=false");
    await page.evaluate(() => {
      for (const [side, value] of Object.entries({ top: 10, bottom: 20, left: 28, right: 28 })) {
        document.documentElement.style.setProperty("--safe-" + side, value + "px");
      }
    });
    await expect(page.getByRole("button", { name: "はじめる" })).toBeVisible();
    // Pairing lives on the home screen only.
    await expect(page.getByRole("button", { name: "リモコン" })).toBeHidden();
    await page.keyboard.press("ArrowRight");
    const number = page.locator(".countdown-number");
    await expect(number).toHaveText("3");
    await expect(number).toBeInViewport({ ratio: 1 });
    await expect(number).toHaveCSS("animation-name", "countdown-pop");
    expect(await page.evaluate(() => document.documentElement.scrollHeight)).toBe(height);
    await expect(page.locator(".progress-count")).toHaveText("1 / 3");
    await expect(page.locator(".progress .clock")).toHaveCount(0);
    await page.locator(".tap-next").click();
    await expect(page.locator(".progress-count")).toHaveText("2 / 3");
    await page.locator(".tap-previous").click();
    await expect(page.locator(".progress-count")).toHaveText("1 / 3");
    expect(await page.evaluate(() => document.documentElement.scrollHeight)).toBe(height);
    await page.keyboard.press("Escape");
    await expect(page.getByText("1. カードを えらぼう")).toBeVisible();
    await page.locator(".header-remote").getByRole("button", { name: "リモコン" }).click();
    await expect(page.locator(".pair-panel")).toBeVisible();
    const box = await page.locator(".pair-panel").boundingBox();
    expect(box.x).toBeGreaterThanOrEqual(28);
    expect(box.y + box.height).toBeLessThanOrEqual(height - 20);
    expect(await page.evaluate(() => document.documentElement.scrollHeight)).toBe(height);
    await page.getByRole("button", { name: "とじる" }).click();
    await expect(page.locator(".pair-panel")).toHaveCount(0);
  });
}

test("the countdown blocks card input and the play clock starts at zero", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.clock.install();
  await page.goto("/#/play/add?count=3");
  await page.getByRole("button", { name: "はじめる" }).click();
  const number = page.locator(".countdown-number");
  const clock = page.locator(".progress .clock");
  await expect(number).toHaveText("3");
  await expect(number).toHaveCSS("animation-name", "none");
  await expect(clock).toHaveCount(0);
  await expect(page.locator(".tap-next")).toHaveCount(0);
  await page.clock.runFor(1_000);
  await expect(number).toHaveText("2");
  await page.keyboard.press("Space");
  await page.clock.runFor(1_000);
  await expect(number).toHaveText("1");
  await page.clock.runFor(1_000);
  await expect(page.locator(".progress-count")).toHaveText("1 / 3");
  await expect(clock).toHaveText("0ふん0びょう");
  await page.clock.runFor(2_500);
  await expect(clock).toHaveText("0ふん2びょう");
  await page.clock.runFor(70_000);
  await expect(clock).toHaveText("1ふん12びょう");
  await page.keyboard.press("Space");
  await expect(page.locator(".progress-count")).toHaveText("2 / 3");
});

test("quitting the countdown leaves the next game ready", async ({ page }) => {
  await page.clock.install();
  await page.goto("/#/play/add?count=3");
  const start = page.getByRole("button", { name: "はじめる" });
  await start.click();
  await expect(page.locator(".countdown-number")).toHaveText("3");
  await page.keyboard.press("Escape");
  const choose = page.getByRole("link", { name: "スタート！" });
  await expect(choose).toBeVisible();
  await choose.click();
  await page.clock.runFor(3_000);
  await expect(start).toBeVisible();
  await start.click();
  await expect(page.locator(".countdown-number")).toHaveText("3");
});

test("solo play tolerates blocked storage and clears records on the next day", async ({ browser }) => {
  const context = await browser.newContext();
  const page = await context.newPage();
  try {
    await page.clock.install({ time: new Date(2026, 10, 14, 23, 59, 50) });
    await page.goto("/#/play/add?count=1");
    await page.getByRole("button", { name: "はじめる" }).click();
    await page.clock.runFor(3_000);
    await expect(page.locator(".progress-count")).toHaveText("1 / 1");
    await page.keyboard.press("ArrowRight");
    await page.getByText("おわり！", { exact: true }).waitFor();
    await page.goto("/#/records");
    await expect(page.locator(".record-row")).toHaveCount(1);
    await page.clock.setSystemTime(new Date(2026, 10, 15, 0, 0, 10));
    await page.goto("/#/stamps");
    await expect(page.locator(".stamp-slot-image")).toHaveCount(0);
    await page.goto("/#/records");
    await expect(page.locator(".record-row")).toHaveCount(0);
    const blocked = await context.newPage();
    await blocked.clock.install();
    await blocked.addInitScript(() => {
      Object.defineProperty(window, "localStorage", { get() { throw new DOMException("blocked", "SecurityError"); } });
    });
    await blocked.goto("/#/play/add?count=1");
    await blocked.getByRole("button", { name: "はじめる" }).click();
    await blocked.clock.runFor(3_000);
    await expect(blocked.locator(".progress-count")).toHaveText("1 / 1");
    await blocked.keyboard.press("ArrowRight");
    await expect(blocked.getByText("おわり！", { exact: true })).toBeVisible();
  } finally { await context.close(); }
});
