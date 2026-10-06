import { randomUUID } from "node:crypto";

import {
  BrowserAccessError,
  closeOrphanedOwnedPages,
  OWNED_PAGE_PREFIX,
} from "./browser.mjs";
import {
  buildEmptyExperienceDiagnostics,
  inspectExperiencePage,
  normalizeExperienceBlocks,
} from "./extraction.mjs";
import { canonicalizeLinkedInProfileUrl } from "./scope.mjs";

export class LinkedInExperienceService {
  #activePages = new Set();
  #cleanedConnection = 0;
  #tail = Promise.resolve();

  constructor({ chromeSession, clock = () => new Date(), navigationTimeoutMs = 30_000 }) {
    this.chromeSession = chromeSession;
    this.clock = clock;
    this.navigationTimeoutMs = navigationTimeoutMs;
  }

  lookup(profileUrl) {
    const canonicalUrl = canonicalizeLinkedInProfileUrl(profileUrl);
    const result = this.#tail.then(async () => {
      try {
        return await this.#lookupLocked(canonicalUrl);
      } catch (error) {
        if (error instanceof BrowserAccessError) error.profileUrl = canonicalUrl;
        throw error;
      }
    });
    this.#tail = result.catch(() => {});
    return result;
  }

  async close() {
    await this.#tail;
    await Promise.all([...this.#activePages].map((page) => page.close({ runBeforeUnload: false }).catch(() => {})));
    this.#activePages.clear();
    await this.chromeSession.disconnect();
  }

  async #lookupLocked(canonicalUrl) {
    const { browser, connectionNumber } = await this.chromeSession.browser();
    if (this.#cleanedConnection !== connectionNumber) {
      await closeOrphanedOwnedPages(browser);
      this.#cleanedConnection = connectionNumber;
    }

    let page;
    try {
      page = await browser.newPage();
      this.#activePages.add(page);
      const marker = `${OWNED_PAGE_PREFIX}${randomUUID()}`;
      await page.evaluate((value) => { window.name = value; }, marker);
      await page.goto(canonicalUrl, {
        timeout: this.navigationTimeoutMs,
        waitUntil: "domcontentloaded",
      });
      await page.evaluate((value) => { window.name = value; }, marker);
      await page.waitForSelector("main", { timeout: 10_000 }).catch(() => {});
      await page.evaluate(async () => {
        for (let step = 0; step < 4; step += 1) {
          window.scrollBy(0, Math.max(window.innerHeight, 800));
          await new Promise((resolve) => setTimeout(resolve, 250));
        }
        window.scrollTo(0, 0);
      });
      const inspected = await page.evaluate(inspectExperiencePage);
      assertUsableLinkedInPage(inspected);
      const evidence = normalizeExperienceBlocks(inspected.blocks);
      if (evidence.length === 0) {
        const diagnostics = buildEmptyExperienceDiagnostics(inspected.signals);
        throw new BrowserAccessError(
          "linkedin_page_changed",
          "Open the profile experience page in the dedicated Symphony LinkedIn Chrome profile on Thor and confirm whether the Experience section and dated entries are visible.",
          "LinkedIn returned no scoped experience evidence.",
          { diagnostics }
        );
      }
      return {
        status: "ok",
        profileUrl: canonicalUrl,
        retrievedAt: this.clock().toISOString(),
        accessMethod: "signed_in_chrome_devtools",
        evidence,
      };
    } catch (error) {
      if (error instanceof BrowserAccessError) throw error;
      const message = error instanceof Error ? error.message : String(error);
      if (/target closed|session closed|connection closed|protocol error|timed out|timeout/i.test(message)) {
        await this.chromeSession.disconnect();
        throw new BrowserAccessError(
          "browser_unavailable",
          "Confirm that Chrome is running on Thor, then retry the blocked dive once.",
          "The Chrome connection ended during the lookup.",
          { cause: error }
        );
      }
      throw error;
    } finally {
      if (page) {
        this.#activePages.delete(page);
        await page.close({ runBeforeUnload: false }).catch(() => {});
      }
    }
  }
}

function assertUsableLinkedInPage(page) {
  let location;
  try {
    location = new URL(page.url);
  } catch {
    location = null;
  }
  const path = location?.pathname.toLowerCase() ?? "";
  const text = `${page.title ?? ""}\n${page.bodyText ?? ""}`;
  if (location?.hostname === "www.linkedin.com" && /\/checkpoint\/(challenge|captcha)/.test(path)) {
    throw new BrowserAccessError(
      "linkedin_challenge",
      "Complete the LinkedIn security challenge in Chrome on Thor.",
      "LinkedIn requires a security challenge."
    );
  }
  if (/security verification|quick security check|captcha|verify your identity/i.test(text)) {
    throw new BrowserAccessError(
      "linkedin_challenge",
      "Complete the LinkedIn security challenge in Chrome on Thor.",
      "LinkedIn requires a security challenge."
    );
  }
  if (
    !location ||
    location.hostname === "login.linkedin.com" ||
    /\/(login|authwall)(?:\/|$)/.test(path) ||
    /sign in to linkedin|join linkedin|welcome back/i.test(text)
  ) {
    throw new BrowserAccessError(
      "login_required",
      "Sign in to LinkedIn in the existing Chrome profile on Thor.",
      "The LinkedIn session is not signed in."
    );
  }
  if (location.hostname !== "www.linkedin.com" || !/\/in\/[^/]+\/details\/experience\/?$/.test(path)) {
    throw new BrowserAccessError(
      "linkedin_page_changed",
      "Open the profile experience page in the dedicated Symphony LinkedIn Chrome profile on Thor and inspect the redirect.",
      "LinkedIn redirected outside the approved profile experience page."
    );
  }
}
