import { chromium } from "@playwright/test";
import { once } from "node:events";
import { createInterface } from "node:readline";

const base = process.env.SPEEDMATH_TEST_URL;
if (!base) throw new Error("Set SPEEDMATH_TEST_URL to the staging URL");
const browser = await chromium.launch();
const input = process.argv.includes("--redeploy") ? createInterface({ input: process.stdin }) : null;
try {
  const presenter = await browser.newPage(), remote = await browser.newPage();
  await presenter.goto(base + "/#/");
  await presenter.locator(".header-remote").getByRole("button", { name: "リモコン" }).click();
  await presenter.locator(".pair-code").waitFor();
  const code = await presenter.locator(".pair-code").textContent();
  await remote.goto(base + "/#/remote");
  await remote.getByRole("textbox", { name: "コード" }).fill(code);
  await remote.getByRole("button", { name: "コードで つなぐ" }).click();
  await presenter.getByRole("button", { name: "つなぐ", exact: true }).click();
  await remote.getByRole("button", { name: "スタート！" }).waitFor();
  // A three-card game, changed in place so the pairing stays; the parent starts it.
  await presenter.evaluate(() => { location.hash = "#/play/add?count=3"; });
  await remote.getByRole("button", { name: "はじめる" }).click();
  await remote.getByText("1 / 3", { exact: true }).waitFor();
  if (input) {
    console.log("Ready. Redeploy the same staging app and then press Enter.");
    await once(input, "line");
  } else {
    console.log("Paired and synchronized; holding both connections idle for 45 seconds");
    await new Promise(resolve => setTimeout(resolve, 45000));
  }
  const before = Date.now();
  await remote.getByRole("button", { name: "つぎ" }).click({ timeout: 20000 });
  await presenter.getByText("2 / 3", { exact: true }).waitFor();
  await remote.getByText("2 / 3", { exact: true }).waitFor();
  console.log("Exactly one step applied and synchronized:", Date.now() - before, "ms");
} finally { input?.close(); await browser.close(); }
