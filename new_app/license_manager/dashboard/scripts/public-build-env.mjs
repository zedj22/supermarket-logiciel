/**
 * Build-time gate for the dashboard's **public** Firebase configuration
 * (Phase 8.3.2).
 *
 * Next.js inlines every `NEXT_PUBLIC_*` value while it compiles, so a
 * `docker build` that forgets the build arguments produces an image whose
 * login page always says "Not configured" — a failure that looks like a
 * Firebase Console mistake. This script runs from `prebuild`, so `npm run build`
 * (and therefore the Docker build) fails at the point of the mistake.
 *
 * It deliberately lives outside `next.config.ts`: Next evaluates the config
 * before it assigns `process.env.NEXT_PHASE`, so a phase check there cannot
 * tell a build from `next start`.
 *
 * Everything named here is public by design (a Firebase Web App config is
 * shipped to browsers). Signing seeds, AES keys, service-account JSON and
 * Secret Manager values must never be build arguments and must never carry a
 * `NEXT_PUBLIC_` prefix; this module only reasons about the public set and the
 * two switches that would make a build unsafe.
 */

import path from "node:path";
import { fileURLToPath } from "node:url";

// `@next/env` is CommonJS; a named ESM import of it fails at load time.
import nextEnv from "@next/env";

const { loadEnvConfig } = nextEnv;

/** Without these the browser bundle cannot sign an administrator in. */
export const REQUIRED_PUBLIC_FIREBASE_VARS = [
  "NEXT_PUBLIC_FIREBASE_API_KEY",
  "NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN",
  "NEXT_PUBLIC_FIREBASE_PROJECT_ID",
  "NEXT_PUBLIC_FIREBASE_APP_ID",
];

/**
 * Only ever legitimate on a developer's machine. Baking either into an image
 * would mean unsigned emulator tokens or a permanent App Check debug token in
 * staging/production.
 */
export const DEVELOPMENT_ONLY_PUBLIC_SWITCHES = [
  "NEXT_PUBLIC_FIREBASE_AUTH_EMULATOR_HOST",
  "NEXT_PUBLIC_FIREBASE_APPCHECK_DEBUG_TOKEN",
];

/** Escape hatch for a deliberate local build; never set it for a deployment. */
export const ALLOW_DEVELOPMENT_SWITCHES_ENV =
  "LICENSE_DASHBOARD_ALLOW_DEVELOPMENT_SWITCHES";

function filled(env, name) {
  return (env[name] ?? "").trim().length > 0;
}

/** Everything wrong with this build configuration, as short sentences. */
export function publicBuildProblems(env, allowDevelopmentSwitches = env[ALLOW_DEVELOPMENT_SWITCHES_ENV] === "1") {
  const problems = [];

  const missing = REQUIRED_PUBLIC_FIREBASE_VARS.filter((name) => !filled(env, name));
  if (missing.length > 0) {
    problems.push(`missing ${missing.join(", ")}`);
  }

  const unsafe = DEVELOPMENT_ONLY_PUBLIC_SWITCHES.filter((name) => filled(env, name));
  if (unsafe.length > 0 && !allowDevelopmentSwitches) {
    problems.push(`development-only switch(es) set: ${unsafe.join(", ")}`);
  }

  return problems;
}

export function formatProblems(problems) {
  return [
    "KlickPOS License Dashboard cannot be built with this configuration:",
    ...problems.map((problem) => `  - ${problem}`),
    "",
    "Next.js inlines NEXT_PUBLIC_* values at build time. Pass the public Firebase web app values",
    "(Firebase Console → Project settings → Your apps → Web app) as build arguments, e.g.",
    "  docker build -f license_manager/dashboard/Dockerfile \\",
    "    --build-arg NEXT_PUBLIC_FIREBASE_PROJECT_ID=<project-id> … license_manager",
    "NEXT_PUBLIC_FIREBASE_AUTH_EMULATOR_HOST and NEXT_PUBLIC_FIREBASE_APPCHECK_DEBUG_TOKEN must stay empty.",
  ].join("\n");
}

function main() {
  // Same env files Next itself reads (.env.local, .env.production, …), with the
  // same precedence: an exported variable always wins.
  loadEnvConfig(process.cwd(), false, { info: () => {}, error: () => {} });

  const unsafe = DEVELOPMENT_ONLY_PUBLIC_SWITCHES.filter((name) => filled(process.env, name));
  if (unsafe.length > 0 && process.env[ALLOW_DEVELOPMENT_SWITCHES_ENV] === "1") {
    // Local builds only, and loud on purpose.
    console.warn(
      `[public-build-env] development-only Firebase switch(es) inlined into this build: ${unsafe.join(", ")}`,
    );
  }

  const problems = publicBuildProblems(process.env);
  if (problems.length > 0) {
    console.error(formatProblems(problems));
    process.exitCode = 1;
    return;
  }
  console.log(`[public-build-env] public Firebase config present for ${process.env.NEXT_PUBLIC_FIREBASE_PROJECT_ID}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
