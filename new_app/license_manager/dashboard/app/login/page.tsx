"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";

import { IconShield } from "@/components/icons";
import { Alert, Button, Spinner } from "@/components/ui";
import { errorMessage } from "@/lib/api";
import { firebaseConfig, isFirebaseConfigured, signInWithGoogle } from "@/lib/firebase";
import { useSession } from "@/lib/session";

function GoogleMark() {
  return (
    <svg aria-hidden="true" width="16" height="16" viewBox="0 0 48 48">
      <path
        fill="#EA4335"
        d="M24 9.5c3.5 0 6.6 1.2 9 3.5l6.7-6.7C35.6 2.5 30.2 0 24 0 14.6 0 6.4 5.4 2.5 13.2l7.8 6.1C12.3 13.2 17.6 9.5 24 9.5z"
      />
      <path
        fill="#4285F4"
        d="M46.1 24.5c0-1.6-.1-3.1-.4-4.5H24v9h12.4c-.5 2.7-2.1 5-4.5 6.6l7.6 5.9c4.4-4.1 6.6-10.1 6.6-17z"
      />
      <path
        fill="#FBBC05"
        d="M10.3 28.7A14.6 14.6 0 0 1 9.5 24c0-1.6.3-3.2.8-4.7l-7.8-6.1A24 24 0 0 0 0 24c0 3.9.9 7.5 2.5 10.8l7.8-6.1z"
      />
      <path
        fill="#34A853"
        d="M24 48c6.2 0 11.4-2 15.5-5.5l-7.6-5.9c-2.1 1.4-4.8 2.3-7.9 2.3-6.4 0-11.7-3.7-13.7-8.8l-7.8 6.1C6.4 42.6 14.6 48 24 48z"
      />
    </svg>
  );
}

/** SDK error → text an administrator can act on (never a provider payload). */
function googleErrorMessage(cause: unknown): string {
  const code = (cause as { code?: string }).code ?? "";
  switch (code) {
    case "auth/popup-closed-by-user":
    case "auth/cancelled-popup-request":
      return "Sign-in cancelled.";
    case "auth/popup-blocked":
      return "Your browser blocked the sign-in popup. Allow popups for this site, then try again.";
    case "auth/unauthorized-domain":
      return "This domain is not authorized in Firebase Authentication (Authentication → Settings → Authorized domains).";
    case "auth/operation-not-allowed":
      return "Google sign-in is not enabled for this Firebase project (Authentication → Sign-in method → Google).";
    case "auth/invalid-api-key":
    case "auth/invalid-credential":
      return "Firebase rejected this web app configuration. Check the NEXT_PUBLIC_FIREBASE_* values and restart the dashboard.";
    case "auth/too-many-requests":
      return "Too many attempts. Wait a few minutes and try again.";
    case "auth/network-request-failed":
      return "Cannot reach Firebase Authentication. Check your connection.";
    default:
      return code ? "Sign-in failed. Please try again." : errorMessage(cause);
  }
}

export default function LoginPage() {
  const router = useRouter();
  const { status } = useSession();
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (status === "authenticated") router.replace("/overview");
  }, [status, router]);

  async function handleGoogleSignIn() {
    setError(null);
    setBusy(true);
    try {
      const user = await signInWithGoogle();
      // The ID token is minted on the first API call; Firebase keeps the
      // session, so navigating here is enough (the layout reads the session).
      if (user) router.replace("/overview");
    } catch (cause) {
      setError(googleErrorMessage(cause));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex min-h-dvh flex-col bg-canvas lg:flex-row">
      {/* Brand panel */}
      <div className="relative hidden flex-1 flex-col justify-between overflow-hidden bg-[hsl(174_60%_12%)] p-10 text-white lg:flex">
        <div
          aria-hidden="true"
          className="pointer-events-none absolute -right-24 -top-24 h-96 w-96 rounded-full bg-[hsl(174_70%_35%)] opacity-30 blur-3xl"
        />
        <div
          aria-hidden="true"
          className="pointer-events-none absolute -bottom-32 -left-16 h-96 w-96 rounded-full bg-[hsl(190_80%_40%)] opacity-20 blur-3xl"
        />
        <div className="relative">
          <div className="flex items-center gap-3">
            <span className="flex h-10 w-10 items-center justify-center rounded-lg bg-white/15 text-sm font-bold">
              KP
            </span>
            <div>
              <p className="text-sm font-semibold tracking-tight">KlickPOS</p>
              <p className="text-xs text-white/70">License Manager</p>
            </div>
          </div>
        </div>
        <div className="relative max-w-md">
          <h1 className="text-3xl font-semibold leading-tight tracking-tight">
            Issue and track lifetime licenses from one private console.
          </h1>
          <p className="mt-4 text-sm leading-relaxed text-white/75">
            Administrative only. Activation codes are signed by the License API and
            shown over audited calls — never generated in this browser.
          </p>
        </div>
        <p className="relative flex items-center gap-2 text-xs text-white/60">
          <IconShield size={14} />
          One administrator allowlist, enforced by the API on every request.
        </p>
      </div>

      {/* Sign-in panel */}
      <div className="flex flex-1 items-center justify-center px-4 py-10 sm:px-8">
        <div className="w-full max-w-sm">
          <div className="mb-8 flex items-center gap-3 lg:hidden">
            <span className="flex h-9 w-9 items-center justify-center rounded-lg bg-accent text-sm font-bold text-white dark:text-canvas">
              KP
            </span>
            <div>
              <p className="text-sm font-semibold text-ink">KlickPOS</p>
              <p className="text-[11px] text-muted">License Manager</p>
            </div>
          </div>

          <h2 className="text-xl font-semibold tracking-tight text-ink">Administrator sign in</h2>
          <p className="mt-1 text-sm text-muted">
            Google is the only sign-in method. Access is limited to the allowlist
            configured on the License API.
          </p>

          <div className="mt-6 space-y-4">
            {isFirebaseConfigured ? (
              <div className="space-y-4">
                {error ? <Alert tone="danger">{error}</Alert> : null}
                <Button
                  type="button"
                  className="w-full"
                  loading={busy}
                  onClick={handleGoogleSignIn}
                >
                  {busy ? (
                    "Opening Google…"
                  ) : (
                    <>
                      <GoogleMark /> Sign in with Google
                    </>
                  )}
                </Button>
                <p className="text-center text-[11px] text-muted">
                  The API verifies the ID token with revocation checking and then
                  checks its administrator allowlist.
                </p>
              </div>
            ) : (
              <div className="space-y-4">
                <Alert tone="danger" title="Not configured">
                  No Firebase web configuration is set, so Google sign-in cannot be
                  offered. There is no development sign-in fallback.
                </Alert>
                <div className="card p-4 text-xs leading-relaxed text-muted">
                  <p className="font-medium text-ink">To finish setup:</p>
                  <ol className="mt-2 list-decimal space-y-1 pl-4">
                    <li>
                      Copy <code className="font-mono">.env.example</code> to{" "}
                      <code className="font-mono">.env.local</code>.
                    </li>
                    <li>
                      Fill in the <code className="font-mono">NEXT_PUBLIC_FIREBASE_*</code>{" "}
                      values from Firebase Console → Project settings → Your apps → Web
                      app, and <code className="font-mono">NEXT_PUBLIC_API_BASE_URL</code>.
                    </li>
                    <li>
                      Add this origin to Authentication → Settings →{" "}
                      <strong>Authorized domains</strong>, and enable{" "}
                      <strong>Google</strong> under Sign-in method.
                    </li>
                    <li>Restart the dev server.</li>
                  </ol>
                </div>
              </div>
            )}

            <p className="text-center text-[11px] text-muted">
              Firebase project:{" "}
              <span className="font-mono">{firebaseConfig.projectId || "not set"}</span>
            </p>

            {status === "loading" ? (
              <p className="flex items-center justify-center gap-2 text-xs text-muted">
                <Spinner size={12} /> Checking session…
              </p>
            ) : null}
          </div>
        </div>
      </div>
    </div>
  );
}
