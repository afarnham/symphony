import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  buildEmptyExperienceDiagnostics,
  inspectExperiencePage,
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

test("collects visible loading and experience signals from offline DOM fixtures", async () => {
  const fixtures = JSON.parse(await readFile(
    new URL("./fixtures/experience-page-dom.json", import.meta.url),
    "utf8"
  ));
  for (const fixture of fixtures) {
    const restore = installFixtureDom(fixture.main);
    try {
      const inspected = inspectExperiencePage();
      const diagnostics = buildEmptyExperienceDiagnostics(inspected.signals);
      assert.deepEqual(
        { ...pick(inspected.signals, Object.keys(fixture.expected)), classification: diagnostics.classification },
        fixture.expected,
        fixture.name
      );
    } finally {
      restore();
    }
  }
});

function pick(value, keys) {
  return Object.fromEntries(keys.filter((key) => key !== "classification").map((key) => [key, value[key]]));
}

function installFixtureDom(fixture) {
  const priorWindow = globalThis.window;
  const priorDocument = globalThis.document;
  const main = new FixtureElement("main", { visible: fixture.visible, ariaBusy: fixture.ariaBusy });
  if (fixture.heading) {
    const section = main.append(new FixtureElement("section"));
    section.append(new FixtureElement("h2", { text: fixture.heading }));
    for (const item of fixture.items) section.append(new FixtureElement("li", item));
  }
  for (const progress of fixture.progress) {
    main.append(new FixtureElement("div", { ...progress, role: "progressbar" }));
  }
  globalThis.window = {
    location: { href: "https://www.linkedin.com/in/example/details/experience/" },
    getComputedStyle: (element) => ({
      display: element.visible ? "block" : "none",
      visibility: element.visible ? "visible" : "hidden",
    }),
  };
  globalThis.document = {
    title: "Example profile",
    body: main,
    querySelector: (selector) => selector === "main" ? main : null,
  };
  return () => {
    globalThis.window = priorWindow;
    globalThis.document = priorDocument;
  };
}

class FixtureElement {
  constructor(tagName, { text = "", visible = true, ariaBusy = false, role = null } = {}) {
    this.tagName = tagName.toLowerCase();
    this.text = text;
    this.visible = visible;
    this.ariaBusy = ariaBusy;
    this.role = role;
    this.children = [];
    this.parentElement = null;
  }

  get innerText() {
    return [this.text, ...this.children.map((child) => child.innerText)].filter(Boolean).join("\n");
  }

  append(child) {
    child.parentElement = this;
    this.children.push(child);
    return child;
  }

  getBoundingClientRect() {
    return { width: this.visible ? 100 : 0, height: this.visible ? 20 : 0 };
  }

  matches(selector) {
    if (selector === '[aria-busy="true"], [role="progressbar"]') {
      return this.ariaBusy || this.role === "progressbar";
    }
    return false;
  }

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] ?? null;
  }

  querySelectorAll(selector) {
    const descendants = this.descendants();
    if (selector === "li") return descendants.filter((element) => element.tagName === "li");
    if (selector === "h1,h2,h3,[role=heading]") {
      return descendants.filter((element) => ["h1", "h2", "h3"].includes(element.tagName) || element.role === "heading");
    }
    if (selector === '[aria-busy="true"], [role="progressbar"]') {
      return descendants.filter((element) => element.matches(selector));
    }
    return [];
  }

  descendants() {
    return this.children.flatMap((child) => [child, ...child.descendants()]);
  }

  closest(selector) {
    let element = this;
    while (element) {
      if (selector === "section" && element.tagName === "section") return element;
      if (selector === "li" && element.tagName === "li") return element;
      element = element.parentElement;
    }
    return null;
  }

  contains(other) {
    return other === this || this.descendants().includes(other);
  }
}
