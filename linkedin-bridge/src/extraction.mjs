export function normalizeExperienceBlocks(blocks) {
  if (!Array.isArray(blocks)) return [];
  return blocks.slice(0, 32).flatMap((block) => {
    if (!block || typeof block !== "object") return [];
    const lines = uniqueStrings(block.lines, 24, 300);
    const dateLines = uniqueStrings(block.dateLines, 8, 300);
    if (lines.length === 0 || dateLines.length === 0) return [];
    const roleText = cleanString(block.roleText, 300);
    const employerText = cleanString(block.employerText, 300);
    return [{
      roleText: roleText || null,
      employerText: employerText || null,
      dateText: dateLines.join(" | "),
      visibleText: lines.join("\n"),
    }];
  });
}

const EMPTY_EXPERIENCE_CLASSIFICATIONS = new Set([
  "page_not_ready",
  "profile_unavailable",
  "experience_section_missing",
  "experience_section_empty",
  "experience_entries_unrecognized",
  "scoped_evidence_rejected",
]);

export function buildEmptyExperienceDiagnostics(signals) {
  const safe = signals && typeof signals === "object" ? signals : {};
  return sanitizeEmptyExperienceDiagnostics({
    schemaVersion: 1,
    classification: classifyEmptyExperience(safe),
    mainPresent: safe.mainPresent === true,
    mainVisible: safe.mainVisible === true,
    experienceHeadingPresent: safe.experienceHeadingPresent === true,
    experienceSectionPresent: safe.experienceSectionPresent === true,
    experienceSectionHasNonHeadingText: safe.experienceSectionHasNonHeadingText === true,
    visibleExperienceItemCount: boundedCount(safe.visibleExperienceItemCount),
    datedCandidateCount: boundedCount(safe.datedCandidateCount),
    loadingIndicatorPresent: safe.loadingIndicatorPresent === true,
    unavailableMarkerPresent: safe.unavailableMarkerPresent === true,
  });
}

export function sanitizeEmptyExperienceDiagnostics(value) {
  if (!value || typeof value !== "object" || value.schemaVersion !== 1) return null;
  if (!EMPTY_EXPERIENCE_CLASSIFICATIONS.has(value.classification)) return null;
  return {
    schemaVersion: 1,
    classification: value.classification,
    mainPresent: value.mainPresent === true,
    mainVisible: value.mainVisible === true,
    experienceHeadingPresent: value.experienceHeadingPresent === true,
    experienceSectionPresent: value.experienceSectionPresent === true,
    experienceSectionHasNonHeadingText: value.experienceSectionHasNonHeadingText === true,
    visibleExperienceItemCount: boundedCount(value.visibleExperienceItemCount),
    datedCandidateCount: boundedCount(value.datedCandidateCount),
    loadingIndicatorPresent: value.loadingIndicatorPresent === true,
    unavailableMarkerPresent: value.unavailableMarkerPresent === true,
  };
}

function classifyEmptyExperience(signals) {
  if (signals.unavailableMarkerPresent === true) return "profile_unavailable";
  if (
    signals.mainPresent !== true ||
    signals.mainVisible !== true ||
    (signals.loadingIndicatorPresent === true && boundedCount(signals.visibleExperienceItemCount) === 0)
  ) {
    return "page_not_ready";
  }
  if (signals.experienceHeadingPresent !== true || signals.experienceSectionPresent !== true) {
    return "experience_section_missing";
  }
  if (boundedCount(signals.visibleExperienceItemCount) === 0) {
    return signals.experienceSectionHasNonHeadingText === true
      ? "experience_entries_unrecognized"
      : "experience_section_empty";
  }
  if (boundedCount(signals.datedCandidateCount) === 0) return "experience_entries_unrecognized";
  return "scoped_evidence_rejected";
}

function boundedCount(value) {
  return Number.isInteger(value) ? Math.min(Math.max(value, 0), 128) : 0;
}

function uniqueStrings(value, limit, maxLength) {
  if (!Array.isArray(value)) return [];
  const seen = new Set();
  const result = [];
  for (const item of value) {
    const clean = cleanString(item, maxLength);
    if (!clean || seen.has(clean)) continue;
    seen.add(clean);
    result.push(clean);
    if (result.length === limit) break;
  }
  return result;
}

function cleanString(value, maxLength) {
  if (typeof value !== "string") return "";
  return value.replace(/\s+/g, " ").trim().slice(0, maxLength);
}

export function inspectExperiencePage() {
  const visible = (element) => {
    const style = window.getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return style.display !== "none" && style.visibility !== "hidden" && rect.width > 0 && rect.height > 0;
  };
  const linesFor = (element) => (element.innerText ?? "")
    .split("\n")
    .map((line) => line.replace(/\s+/g, " ").trim())
    .filter(Boolean)
    .filter((line, index, values) => values.indexOf(line) === index);
  const datePattern = /(?:\b(?:19|20)\d{2}\b|\bpresent\b|\bcurrent\b|\bactualidad\b|\bpresente\b|\bprésent\b|\bheute\b|\boggi\b|\bhoje\b)/i;
  const main = document.querySelector("main");
  const bodyText = (main?.innerText ?? document.body?.innerText ?? "").slice(0, 20_000);
  const headingPattern = /^(?:experience|experiencia|expérience|berufserfahrung|esperienza|experiência)$/i;
  const experienceHeading = main
    ? [...main.querySelectorAll("h1,h2,h3,[role=heading]")]
      .find((heading) => visible(heading) && headingPattern.test((heading.innerText ?? "").trim()))
    : null;
  const experienceSection = experienceHeading?.closest("section") ?? null;
  const experienceSectionHasNonHeadingText = Boolean(
    experienceSection && linesFor(experienceSection).some((line) => !headingPattern.test(line))
  );
  const loadingIndicatorPresent = Boolean(
    main?.querySelector('[aria-busy="true"], [role="progressbar"]')
  );
  const unavailableMarkerPresent = /(?:this profile is not available|profile not found|profile unavailable|the profile you(?:'|’)re looking for (?:isn(?:'|’)t|is not) public or doesn(?:'|’)t|this page doesn(?:'|’)t exist)/i
    .test(bodyText);
  const visibleExperienceItems = experienceSection
    ? [...experienceSection.querySelectorAll("li")].filter((item) => visible(item))
    : [];
  const candidates = main
    ? [...main.querySelectorAll("li")].filter((item) => visible(item) && linesFor(item).some((line) => datePattern.test(line)))
    : [];
  const leaves = candidates.filter((item) => !candidates.some((other) => other !== item && item.contains(other)));
  const blocks = leaves.map((item) => {
    const lines = linesFor(item).slice(0, 24);
    const dateLines = lines.filter((line) => datePattern.test(line));
    const labels = lines.filter((line) => !datePattern.test(line));
    let employerText = labels[1] ?? "";
    if (!employerText) {
      let parent = item.parentElement?.closest("li");
      while (parent && !employerText) {
        employerText = linesFor(parent).find((line) => !datePattern.test(line) && line !== labels[0]) ?? "";
        parent = parent.parentElement?.closest("li");
      }
    }
    return { lines, dateLines, roleText: labels[0] ?? "", employerText };
  });
  return {
    url: window.location.href,
    title: document.title,
    bodyText,
    blocks,
    signals: {
      mainPresent: Boolean(main),
      mainVisible: Boolean(main && visible(main)),
      experienceHeadingPresent: Boolean(experienceHeading),
      experienceSectionPresent: Boolean(experienceSection),
      experienceSectionHasNonHeadingText,
      visibleExperienceItemCount: Math.min(visibleExperienceItems.length, 128),
      datedCandidateCount: Math.min(candidates.length, 128),
      loadingIndicatorPresent,
      unavailableMarkerPresent,
    },
  };
}
