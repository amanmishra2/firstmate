# Playwright browser verification harness

This directory provides a deterministic browser smoke and verification harness alongside `chrome-devtools-axi`.
It is deliberately kept out of the agent-model path and does not enter agent prompts, skills, or model-facing instructions.
It is an opt-in verification entry kept out of the default test suite and CI gate.

## Host prerequisites

The harness requires Node.js and a one-time installation of the Chromium browser binary.
If Chromium is not yet installed on the host, run the one-time install command:

```sh
npx --prefix tests/playwright playwright install chromium
```

## Running the smoke test

Run the deterministic smoke spec in headless mode from the repository root:

```sh
npm --prefix tests/playwright test
```

Or run the named smoke script:

```sh
npm --prefix tests/playwright run test:smoke
```

Alternatively, invoke it from within this directory:

```sh
cd tests/playwright && npm test
```

The smoke spec launches Chromium against the local fixture page `fixtures/smoke.html` using a `file://` URL without external network access and asserts the rendered page content.
