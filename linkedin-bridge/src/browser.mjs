import { readFile } from "node:fs/promises";

import puppeteer from "puppeteer-core";

export const OWNED_PAGE_PREFIX = "__symphony_linkedin_bridge__:";

export class BrowserAccessError extends Error {
  constructor(reason, action, message, options) {
    super(message, options);
    this.name = "BrowserAccessError";
    this.reason = reason;
    this.action = action;
  }
}

export class ChromeSession {
  #browser = null;
  #connectionNumber = 0;
  #connectPromise = null;

  constructor({ userDataDir, connectTimeoutMs = 15_000 }) {
    this.userDataDir = userDataDir;
    this.connectTimeoutMs = connectTimeoutMs;
  }

  async browser() {
    if (this.#browser?.connected) {
      return { browser: this.#browser, connectionNumber: this.#connectionNumber };
    }
    if (!this.#connectPromise) {
      this.#connectPromise = this.#connect().finally(() => {
        this.#connectPromise = null;
      });
    }
    return this.#connectPromise;
  }

  async disconnect() {
    if (this.#browser) {
      this.#browser.disconnect();
      this.#browser = null;
    }
  }

  async #connect() {
    const activePortFile = `${this.userDataDir}/DevToolsActivePort`;
    let endpoint;
    try {
      const lines = (await readFile(activePortFile, "utf8"))
        .split("\n")
        .map((line) => line.trim())
        .filter(Boolean);
      const port = Number(lines[0]);
      const path = lines[1];
      if (!Number.isInteger(port) || port < 1 || port > 65_535) {
        throw new Error("The DevTools port is invalid.");
      }
      if (!/^\/devtools\/browser\/[A-Za-z0-9-]+$/.test(path ?? "")) {
        throw new Error("The DevTools browser path is invalid.");
      }
      endpoint = `ws://127.0.0.1:${port}${path}`;
    } catch (error) {
      throw new BrowserAccessError(
        "browser_unavailable",
        "Start Chrome on Thor and enable remote debugging in chrome://inspect/#remote-debugging.",
        "Chrome DevToolsActivePort is unavailable or invalid.",
        { cause: error }
      );
    }

    let timedOut = false;
    const pending = puppeteer.connect({
      browserWSEndpoint: endpoint,
      defaultViewport: null,
      protocolTimeout: 30_000,
    });
    pending.then((browser) => {
      if (timedOut) browser.disconnect();
    }).catch(() => {});

    let browser;
    try {
      browser = await Promise.race([
        pending,
        new Promise((_, reject) => {
          setTimeout(() => {
            timedOut = true;
            reject(new Error("Chrome connection permission timed out."));
          }, this.connectTimeoutMs).unref();
        }),
      ]);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const permission = timedOut || /403|permission|handshake|unexpected server response/i.test(message);
      throw new BrowserAccessError(
        permission ? "permission_required" : "browser_unavailable",
        permission
          ? "Approve the incoming debugging connection in Chrome on Thor."
          : "Start Chrome on Thor and enable remote debugging in chrome://inspect/#remote-debugging.",
        permission ? "Chrome needs debugging permission." : "Chrome is not accepting DevTools connections.",
        { cause: error }
      );
    }

    browser.once("disconnected", () => {
      if (this.#browser === browser) this.#browser = null;
    });
    this.#browser = browser;
    this.#connectionNumber += 1;
    return { browser, connectionNumber: this.#connectionNumber };
  }
}

export async function closeOrphanedOwnedPages(browser) {
  const pages = await browser.pages();
  await Promise.all(pages.map(async (page) => {
    try {
      const marker = await page.evaluate(() => window.name);
      if (typeof marker === "string" && marker.startsWith(OWNED_PAGE_PREFIX)) {
        await page.close({ runBeforeUnload: false });
      }
    } catch {
      // An unrelated tab can disappear during inspection. Never close it by guess.
    }
  }));
}
