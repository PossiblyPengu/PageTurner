import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import process from "node:process";
import { zipSync, strToU8 } from "../docs/vendor/fflate.mjs";

let dir;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "pt-release-"));
  const plist = `<?xml version="1.0"?><plist version="1.0"><dict>
    <key>CFBundleShortVersionString</key><string>2.7.0</string>
    <key>CFBundleVersion</key><string>110</string>
    <key>CFBundleIdentifier</key><string>io.github.possiblypengu.pageturner</string>
  </dict></plist>`;
  writeFileSync(join(dir, "Pageturner.ipa"), zipSync({ "Payload/Pageturner.app/Info.plist": strToU8(plist) }));
  writeFileSync(join(dir, "gh"), `#!/usr/bin/env node
import fs from "node:fs";
const args = process.argv.slice(2);
fs.appendFileSync(process.env.RELEASE_LOG, JSON.stringify(args) + "\\n");
if (args[1] === "view") {
  if (args[2] === "ios-latest") process.exit(process.env.ROLLING_EXISTS === "1" ? 0 : 1);
  process.exit(1);
}
if (process.env.FAIL_STEP === args[1] + ":" + args[2]) process.exit(1);
`, { mode: 0o755 });
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));
const run = (extra = {}) => spawnSync("bash", [resolve("ios/scripts/publish-release.sh"), dir, "a".repeat(40), "42"], {
  env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, REPO: "owner/repo", RELEASE_LOG: join(dir, "commands"), ROLLING_EXISTS: "1", ...extra }, encoding: "utf8",
});
const calls = () => readFileSync(join(dir, "commands"), "utf8").trim().split("\n").map(JSON.parse);

// The script hands the AltStore source to Python, as the macOS runner has it. Where the shell has no
// working python3 (Windows' Store alias answers but runs nothing), there is nothing here to check.
const hasPython = spawnSync("bash", ["-c", "python3 --version"], { encoding: "utf8" }).status === 0;

describe.skipIf(!hasPython)("safe iOS publication", () => {
  it("publishes a complete build before replacing the rolling aliases", () => {
    const result = run();
    expect(result.status, result.stderr).toBe(0);
    const commands = calls();
    const publish = commands.findIndex((c) => c[1] === "edit" && c[2] === "ios-build-42");
    const rolling = commands.findIndex((c) => c[1] === "upload" && c[2] === "ios-latest");
    expect(publish).toBeGreaterThan(-1);
    expect(rolling).toBeGreaterThan(publish);
    expect(commands.some((c) => c.includes("delete"))).toBe(false);
    const source = JSON.parse(readFileSync(join(dir, "altstore.json")));
    // SideStore's quick fields point at the rolling alias (always the newest build); the
    // versions row keeps this build's own URL so the history it grows installs what it names.
    expect(source.apps[0].downloadURL).toBe("https://github.com/owner/repo/releases/download/ios-latest/Pageturner.ipa");
    expect(source.apps[0].versions[0].downloadURL).toBe("https://github.com/owner/repo/releases/download/ios-build-42/Pageturner.ipa");
    expect(source.apps[0].versions[0].buildVersion).toBe("110");
  });

  it.each(["create:ios-build-42", "edit:ios-build-42"])("does not touch the working release when %s fails", (step) => {
    expect(run({ FAIL_STEP: step }).status).toBe(1);
    expect(calls().some((c) => c[2] === "ios-latest")).toBe(false);
  });

  it("retains the published build when an alias upload fails", () => {
    expect(run({ FAIL_STEP: "upload:ios-latest" }).status).toBe(1);
    expect(calls().some((c) => c[1] === "edit" && c[2] === "ios-build-42")).toBe(true);
    expect(calls().some((c) => c.includes("delete"))).toBe(false);
  });

  it("creates the rolling release on a first publication", () => {
    const result = run({ ROLLING_EXISTS: "0" });
    expect(result.status, result.stderr).toBe(0);
    expect(calls().some((c) => c[1] === "create" && c[2] === "ios-latest")).toBe(true);
  });

  it("rejects a damaged IPA before making release requests", () => {
    writeFileSync(join(dir, "Pageturner.ipa"), "not a zip");
    expect(run().status).not.toBe(0);
    expect(() => calls()).toThrow();
  });
});
