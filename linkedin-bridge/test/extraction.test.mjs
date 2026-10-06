import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  buildEmptyExperienceDiagnostics,
  normalizeExperienceBlocks,
} from "../src/extraction.mjs";

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

test("classifies bounded empty-extraction diagnostics from synthetic inspections", async () => {
  const fixtures = JSON.parse(await readFile(
    new URL("./fixtures/empty-experience-inspections.json", import.meta.url),
    "utf8"
  ));
  for (const fixture of fixtures) {
    const diagnostics = buildEmptyExperienceDiagnostics(fixture.signals);
    assert.equal(diagnostics.classification, fixture.classification, fixture.name);
    assert.deepEqual(Object.keys(diagnostics), [
      "schemaVersion",
      "classification",
      "mainPresent",
      "mainVisible",
      "experienceHeadingPresent",
      "experienceSectionPresent",
      "experienceSectionHasNonHeadingText",
      "visibleExperienceItemCount",
      "datedCandidateCount",
      "loadingIndicatorPresent",
      "unavailableMarkerPresent",
    ]);
  }
});

test("diagnostics discard arbitrary data and clamp counts", () => {
  assert.deepEqual(buildEmptyExperienceDiagnostics({
    mainPresent: true,
    mainVisible: true,
    experienceHeadingPresent: true,
    experienceSectionPresent: true,
    experienceSectionHasNonHeadingText: true,
    visibleExperienceItemCount: 9_999,
    datedCandidateCount: -4,
    loadingIndicatorPresent: false,
    unavailableMarkerPresent: false,
    bodyText: "private profile text",
    cookies: "secret",
  }), {
    schemaVersion: 1,
    classification: "experience_entries_unrecognized",
    mainPresent: true,
    mainVisible: true,
    experienceHeadingPresent: true,
    experienceSectionPresent: true,
    experienceSectionHasNonHeadingText: true,
    visibleExperienceItemCount: 128,
    datedCandidateCount: 0,
    loadingIndicatorPresent: false,
    unavailableMarkerPresent: false,
  });
});
