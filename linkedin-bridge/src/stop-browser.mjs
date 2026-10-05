import { ChromeSession } from "./browser.mjs";

const [userDataDir] = process.argv.slice(2);

if (userDataDir) {
  try {
    const session = new ChromeSession({ userDataDir, connectTimeoutMs: 5_000 });
    const { browser } = await session.browser();
    await browser.close();
  } catch {
    // Best effort: systemd will terminate the service if Chrome is already unavailable.
  }
}
