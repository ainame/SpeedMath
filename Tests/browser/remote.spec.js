import { test, expect } from "@playwright/test";
import jsQR from "jsqr";
import { PNG } from "pngjs";

async function presenter(page, count = 3) {
  await page.goto("/#/play/add?count=" + count);
  await page.getByRole("button", { name: "リモコン" }).click();
  await expect(page.locator(".pair-qr")).toBeVisible();
}

async function codeJoin(page, remote) {
  const code = await page.locator(".pair-code").textContent();
  await remote.goto("/#/remote");
  await remote.getByRole("textbox", { name: "コード" }).fill(code.toLowerCase().replaceAll("-", " "));
  await remote.getByRole("button", { name: "コードで つなぐ" }).click();
}

async function approve(page, remote) {
  await expect(remote.getByText("しょうにんを まっています")).toBeVisible();
  await expect(remote.locator(".remote-answer")).toHaveCount(0);
  await expect(remote.getByRole("button", { name: "つぎ →" })).toHaveCount(0);
  await expect(page.locator(".pair-code")).toHaveText(await remote.locator(".pair-code").textContent());
  await page.getByRole("button", { name: "つなぐ", exact: true }).click();
  await expect(remote.getByText("はじまるのを まっています")).toBeVisible();
  await page.getByRole("button", { name: "とじる" }).click();
}

test("code, approval, lost ACK, disconnect, and exactly one finish", async ({ page, browser }) => {
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
    await page.getByRole("button", { name: "はじめる" }).click();
    await expect(remote.locator(".remote-count")).toHaveText("1 / 3");
    await expect(remote.locator(".remote-answer")).toHaveText(/こたえ：\d+/);
    await expect(page.getByText("こたえ：", { exact: false })).toHaveCount(0);
    await remote.getByRole("button", { name: "つぎ →" }).click();
    await expect(page.locator(".progress-count")).toHaveText("2 / 3");
    await expect(remote.getByRole("button", { name: "つぎ →" })).toBeEnabled();
    expect(dropped).toBe(1);
    await expect(page.locator(".progress-count")).toHaveText("2 / 3");
    await remoteContext.setOffline(true);
    await expect(remote.getByRole("button", { name: "つぎ →" })).toBeDisabled();
    await expect(remote.locator(".remote-answer")).toBeVisible();
    await page.keyboard.press("ArrowLeft");
    await expect(page.locator(".progress-count")).toHaveText("1 / 3");
    await remoteContext.setOffline(false);
    await expect(remote.locator(".remote-count")).toHaveText("1 / 3");
    await expect(remote.getByRole("button", { name: "つぎ →" })).toBeEnabled();
    await remote.getByRole("button", { name: "つぎ →" }).click();
    await remote.getByRole("button", { name: "← まえ" }).click();
    await expect(page.locator(".progress-count")).toHaveText("1 / 3");
    for (let i = 0; i < 3; i++) await remote.getByRole("button", { name: "つぎ →" }).click();
    await expect(page.getByText("おわり！", { exact: true })).toBeVisible();
    await expect(remote.getByText("おわり！", { exact: true })).toBeVisible();
    await page.goto("/#/records");
    await expect(page.locator(".record-row")).toHaveCount(1);
    await page.goto("/#/stamps");
    await expect(page.locator(".stamp-slot-image")).toHaveCount(1);
  } finally { await remoteContext.close(); }
});

test("decode the displayed QR, strip invite, reload Presenter, and revoke", async ({ page, browser }) => {
  const context = await browser.newContext();
  const remote = await context.newPage();
  try {
    await presenter(page, 2);
    const png = PNG.sync.read(await page.locator(".pair-qr").screenshot());
    const decoded = jsQR(new Uint8ClampedArray(png.data), png.width, png.height);
    expect(decoded?.data).toContain("/#/remote?invite=");
    await remote.goto(decoded.data);
    await approve(page, remote);
    await expect(remote).toHaveURL(/#\/remote$/);
    await page.keyboard.press("Space");
    await expect(remote.locator(".remote-count")).toHaveText("1 / 2");
    await remote.getByRole("button", { name: "つぎ →" }).click();
    await expect(page.locator(".progress-count")).toHaveText("2 / 2");
    await page.reload();
    await expect(remote.getByText("はじまるのを まっています")).toBeVisible();
    await page.getByRole("button", { name: "はじめる" }).click();
    await expect(remote.locator(".remote-count")).toHaveText("1 / 2");
    await page.getByRole("button", { name: "リモコン" }).click();
    await page.getByRole("button", { name: "リモコンを はずす" }).click();
    await expect(remote.getByRole("textbox", { name: "コード" })).toBeVisible();
    await expect(remote.locator(".remote-answer")).toHaveCount(0);
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
    await page.keyboard.press("ArrowRight");
    await expect(page.locator(".progress-count")).toHaveText("1 / 3");
    await expect(page.locator(".progress .clock")).toHaveCount(0);
    await page.locator(".tap-next").click();
    await expect(page.locator(".progress-count")).toHaveText("2 / 3");
    await page.locator(".tap-previous").click();
    await expect(page.locator(".progress-count")).toHaveText("1 / 3");
    await page.getByRole("button", { name: "リモコン" }).click();
    await expect(page.locator(".pair-panel")).toBeVisible();
    const box = await page.locator(".pair-panel").boundingBox();
    expect(box.x).toBeGreaterThanOrEqual(28);
    expect(box.y + box.height).toBeLessThanOrEqual(height - 20);
    expect(await page.evaluate(() => document.documentElement.scrollHeight)).toBe(height);
    await page.keyboard.press("Escape");
    await page.keyboard.press("Escape");
    await expect(page.getByText("1. カードを えらぼう")).toBeVisible();
    const remoteLink = page.getByRole("link", { name: "リモコン" });
    await expect(remoteLink).toBeVisible();
    const [linkBox, titleBox] = await Promise.all([
      remoteLink.boundingBox(), page.getByRole("heading", { name: "スピードけいさん" }).boundingBox(),
    ]);
    expect(linkBox.x + linkBox.width).toBeLessThan(titleBox.x);
    await remoteLink.click();
    await expect(page.getByRole("textbox", { name: "コード" })).toBeVisible();
  });
}
