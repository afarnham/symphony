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
  };
}
