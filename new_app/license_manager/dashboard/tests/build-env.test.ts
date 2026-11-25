/**
 * The build-time public Firebase configuration gate (Phase 8.3.2).
 *
 * These tests exist because the failure they prevent is invisible until
 * deployment: Next.js inlines `NEXT_PUBLIC_*` at build time, so a forgotten
 * build argument yields a working image whose sign-in page says "Not
 * configured".
 *
 * The gate is `scripts/public-build-env.mjs`, run by `prebuild`. It is exercised
 * as a child process, so the exit code Docker relies on is really tested, and
 * in an empty temporary directory so no `.env.local` can leak in. No real
 * Firebase value appears anywhere: the fixtures are obvious test strings.
 */

import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

const SCRIPT = join(process.cwd(), "scripts", "public-build-env.mjs");

const COMPLETE: Record<string, string> = {
  NEXT_PUBLIC_FIREBASE_API_KEY: "test-public-key",
  NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN: "test-project.firebaseapp.com",
  NEXT_PUBLIC_FIREBASE_PROJECT_ID: "test-project",
  NEXT_PUBLIC_FIREBASE_APP_ID: "1:1:web:test",
  NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID: "1",
  PATH: process.env.PATH ?? "",
};

function runGate(env: Record<string, string | undefined>): {
  status: number;
  output: string;
} {
  const result = spawnSync(process.execPath, [SCRIPT], {
    cwd: tmpdir(), // no .env files here
    env: env as NodeJS.ProcessEnv,
    encoding: "utf8",
  });
  return {
    status: result.status ?? 1,
    output: `${result.stdout ?? ""}${result.stderr ?? ""}`,
  };
}

describe("public Firebase build configuration gate", () => {
  it("exits zero with a complete public configuration", () => {
    const { status, output } = runGate(COMPLETE);

    expect(status).toBe(0);
    expect(output).toContain("test-project");
  });

  it("never echoes the API key", () => {
    const { output } = runGate(COMPLETE);
    expect(output).not.toContain("test-public-key");
  });

  it("exits non-zero when the configuration is missing", () => {
    const { status, output } = runGate({ PATH: process.env.PATH ?? "" });

    expect(status).toBe(1);
    expect(output).toContain("cannot be built with this configuration");
  });

  it("names every missing required value", () => {
    const { output } = runGate({ PATH: process.env.PATH ?? "" });

    for (const name of [
      "NEXT_PUBLIC_FIREBASE_API_KEY",
      "NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN",
      "NEXT_PUBLIC_FIREBASE_PROJECT_ID",
      "NEXT_PUBLIC_FIREBASE_APP_ID",
    ]) {
      expect(output).toContain(name);
    }
  });

  it("treats a whitespace-only value as missing", () => {
    const { status, output } = runGate({
      ...COMPLETE,
      NEXT_PUBLIC_FIREBASE_PROJECT_ID: "   ",
    });

    expect(status).toBe(1);
    expect(output).toContain("NEXT_PUBLIC_FIREBASE_PROJECT_ID");
  });

  it("does not require the optional values (App Check key, sender, bucket)", () => {
    const minimal = {
      NEXT_PUBLIC_FIREBASE_API_KEY: "test-public-key",
      NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN: "test-project.firebaseapp.com",
      NEXT_PUBLIC_FIREBASE_PROJECT_ID: "test-project",
      NEXT_PUBLIC_FIREBASE_APP_ID: "1:1:web:test",
      PATH: process.env.PATH ?? "",
    };
    expect(runGate(minimal).status).toBe(0);
  });

  it("refuses to inline the auth emulator", () => {
    const { status, output } = runGate({
      ...COMPLETE,
      NEXT_PUBLIC_FIREBASE_AUTH_EMULATOR_HOST: "127.0.0.1:9099",
    });

    expect(status).toBe(1);
    expect(output).toContain("NEXT_PUBLIC_FIREBASE_AUTH_EMULATOR_HOST");
  });

  it("refuses to inline an App Check debug token", () => {
    const { status, output } = runGate({
      ...COMPLETE,
      NEXT_PUBLIC_FIREBASE_APPCHECK_DEBUG_TOKEN: "11111111-2222-3333-4444-555555555555",
    });

    expect(status).toBe(1);
    expect(output).toContain("NEXT_PUBLIC_FIREBASE_APPCHECK_DEBUG_TOKEN");
  });

  it("can be bypassed deliberately for a local build, loudly", () => {
    const { status, output } = runGate({
      ...COMPLETE,
      NEXT_PUBLIC_FIREBASE_APPCHECK_DEBUG_TOKEN: "debug-token",
      LICENSE_DASHBOARD_ALLOW_DEVELOPMENT_SWITCHES: "1",
    });

    expect(status).toBe(0);
    expect(output).toContain("development-only");
  });

  it("tells the operator what to pass, without inventing a value", () => {
    const { output } = runGate({ PATH: process.env.PATH ?? "" });
    expect(output).toContain("build-arg");
    expect(output).toContain("must stay empty");
  });
});
