import assert from "node:assert/strict";
import test from "node:test";

import { canonicalizeLinkedInProfileUrl } from "../src/scope.mjs";

test("canonicalizes one LinkedIn profile experience URL and removes parameters", () => {
  assert.equal(
    canonicalizeLinkedInProfileUrl("https://www.linkedin.com/in/example-person/?trk=private#fragment"),
    "https://www.linkedin.com/in/example-person/details/experience/"
  );
  assert.equal(
    canonicalizeLinkedInProfileUrl("https://www.linkedin.com/in/example-person/details/experience/"),
    "https://www.linkedin.com/in/example-person/details/experience/"
  );
});

test("rejects all non-profile and non-LinkedIn destinations", () => {
  for (const url of [
    "https://linkedin.com/in/example",
    "https://www.linkedin.com/company/example",
    "https://www.linkedin.com/messaging/",
    "https://www.linkedin.com/in/example/details/contact-info/",
    "https://www.linkedin.com/in/example%2Fmessaging",
    "http://www.linkedin.com/in/example",
  ]) {
    assert.throws(() => canonicalizeLinkedInProfileUrl(url), TypeError, url);
  }
});
