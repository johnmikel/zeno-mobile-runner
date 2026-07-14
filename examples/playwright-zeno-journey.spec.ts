import { test } from "@playwright/test";

test("guest checkout", {
  annotation: {
    type: "zeno:journey",
    description: "checkout.guest",
  },
}, async ({ page }) => {
  await page.goto("/checkout");
});
