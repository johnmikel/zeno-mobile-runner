// The web half of the cross-platform evidence example. Nothing here is
// Zeno-specific: it is an ordinary Playwright test. Zeno attaches at the
// reporter, which is the whole point — bring your own driver.
import { fileURLToPath } from "node:url";
import { expect, test } from "@playwright/test";

const page_url = `file://${fileURLToPath(new URL("./checkout.html", import.meta.url))}`;

test("a shopper can complete checkout", async ({ page }) => {
  await page.goto(page_url);
  await page.fill("#email", "riley@example.com");
  await page.click("#pay");
  await expect(page.locator("#receipt")).toBeVisible();
  await expect(page.locator("#who")).toHaveText("riley@example.com");
});
