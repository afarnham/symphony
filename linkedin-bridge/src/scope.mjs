const LINKEDIN_HOST = "www.linkedin.com";
const PROFILE_PATH = /^\/in\/([^/]+?)(?:\/details\/experience)?\/?$/;

export function canonicalizeLinkedInProfileUrl(value) {
  if (typeof value !== "string" || value.length > 2_048) {
    throw new TypeError("profileUrl must be a string of at most 2048 characters.");
  }

  let input;
  try {
    input = new URL(value);
  } catch {
    throw new TypeError("profileUrl must be an absolute URL.");
  }
  if (input.protocol !== "https:" || input.hostname.toLowerCase() !== LINKEDIN_HOST) {
    throw new TypeError("profileUrl must use https://www.linkedin.com.");
  }
  if (input.username || input.password || input.port) {
    throw new TypeError("profileUrl cannot contain credentials or a port.");
  }

  const match = input.pathname.match(PROFILE_PATH);
  const slug = match?.[1];
  if (
    !slug ||
    slug.length > 200 ||
    !/^[A-Za-z0-9._%~-]+$/.test(slug) ||
    /%(?:2f|5c)/i.test(slug)
  ) {
    throw new TypeError("profileUrl must identify one LinkedIn /in/ profile.");
  }

  return `https://${LINKEDIN_HOST}/in/${slug}/details/experience/`;
}
