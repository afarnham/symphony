import assert from "node:assert/strict";
import test from "node:test";

import { normalizeExperienceBlocks } from "../src/extraction.mjs";

test("keeps scoped visible evidence and removes duplicates", () => {
  assert.deepEqual(normalizeExperienceBlocks([{
    lines: ["Chef ejecutivo", "Restaurant Example", "feb 2015 - actualidad", "Restaurant Example"],
    dateLines: ["feb 2015 - actualidad", "feb 2015 - actualidad"],
    roleText: "Chef ejecutivo",
    employerText: "Restaurant Example",
  }]), [{
    roleText: "Chef ejecutivo",
    employerText: "Restaurant Example",
    dateText: "feb 2015 - actualidad",
    visibleText: "Chef ejecutivo\nRestaurant Example\nfeb 2015 - actualidad",
  }]);
});

test("drops blocks without visible date text", () => {
  assert.deepEqual(normalizeExperienceBlocks([{ lines: ["Advertisement"], dateLines: [] }]), []);
});
