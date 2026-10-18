import { test, expect } from '@playwright/test';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

test.describe('Deterministic browser smoke', () => {
  test('renders local fixture page without external network', async ({ page }) => {
    const fixturePath = path.resolve(__dirname, '../fixtures/smoke.html');
    await page.goto(`file://${fixturePath}`);

    await expect(page.locator('h1')).toHaveText('Firstmate Playwright Harness Smoke Fixture');
    await expect(page.locator('#status')).toHaveText('deterministic-ready');
    await expect(page.locator('#content')).toHaveText('Browser verification harness active');
  });
});
