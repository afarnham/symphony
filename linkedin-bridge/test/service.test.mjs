import assert from "node:assert/strict";
import test from "node:test";

import { LinkedInExperienceService } from "../src/service.mjs";

test("serializes lookups and closes only its created or orphaned pages", async () => {
  let active = 0;
  let maximum = 0;
  const created = [];
  const unrelated = { closeCalls: 0 };
  const orphaned = { closeCalls: 0 };
  const browser = {
    async pages() { return [unrelated, orphaned]; },
    async newPage() {
      active += 1;
      maximum = Math.max(maximum, active);
      const page = fakePage(() => { active -= 1; });
      created.push(page);
      return page;
    },
  };
  const session = {
    async browser() { return { browser, connectionNumber: 1 }; },
    async disconnect() {},
  };
  unrelated.evaluate = async () => "ordinary-user-tab";
  unrelated.close = async () => { unrelated.closeCalls += 1; };
  orphaned.evaluate = async () => "__symphony_linkedin_bridge__:orphan";
  orphaned.close = async () => { orphaned.closeCalls += 1; };
  const service = new LinkedInExperienceService({
    chromeSession: session,
    clock: () => new Date("2026-10-05T12:00:00.000Z"),
  });

  const [one, two] = await Promise.all([
    service.lookup("https://www.linkedin.com/in/example-one"),
    service.lookup("https://www.linkedin.com/in/example-two"),
  ]);

  assert.equal(maximum, 1);
  assert.equal(unrelated.closeCalls, 0);
  assert.equal(orphaned.closeCalls, 1);
  assert.equal(created.length, 2);
  assert.ok(created.every((page) => page.closeCalls === 1));
  assert.equal(one.profileUrl, "https://www.linkedin.com/in/example-one/details/experience/");
  assert.equal(two.retrievedAt, "2026-10-05T12:00:00.000Z");
});

function fakePage(onClose) {
  return {
    closeCalls: 0,
    async evaluate(value) {
      if (typeof value === "function" && value.name === "inspectExperiencePage") {
        return {
          url: "https://www.linkedin.com/in/example/details/experience/",
          title: "Experience",
          bodyText: "Experience",
          blocks: [{
            lines: ["Chef", "Example Restaurant", "2020 - Present"],
            dateLines: ["2020 - Present"],
            roleText: "Chef",
            employerText: "Example Restaurant",
          }],
        };
      }
    },
    async goto() { await new Promise((resolve) => setTimeout(resolve, 15)); },
    async waitForSelector() {},
    async close() {
      this.closeCalls += 1;
      onClose();
    },
  };
}
