"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import type { ReactNode } from "react";

import { createApiClient, defaultApiBaseUrl, type ApiClient } from "./api";
import { currentAppCheckToken } from "./app-check";
import {
  currentIdToken,
  firebaseAuth,
  isFirebaseConfigured,
  signOutAdmin,
  subscribeToAuth,
} from "./firebase";

export type SessionStatus = "loading" | "authenticated" | "unauthenticated";

export interface AdminUser {
  uid: string;
  email: string | null;
}

export interface SessionValue {
  status: SessionStatus;
  admin: AdminUser | null;
  client: ApiClient;
  signOut: () => Promise<void>;
  /** Re-derive the session from Firebase (used after a popup sign-in). */
  refresh: () => Promise<void>;
}

export const SessionContext = createContext<SessionValue | null>(null);

export function useSession(): SessionValue {
  const value = useContext(SessionContext);
  if (!value) {
    throw new Error("useSession must be used inside <SessionProvider>.");
  }
  return value;
}

/** Build a session value for tests (no Firebase, no network). */
export function createSession(
  client: ApiClient,
  overrides: Partial<SessionValue> = {},
): SessionValue {
  return {
    status: "authenticated",
    admin: { uid: "admin-1", email: "admin@example.com" },
    client,
    signOut: async () => undefined,
    refresh: async () => undefined,
    ...overrides,
  };
}

export function SessionProvider({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<SessionStatus>("loading");
  const [admin, setAdmin] = useState<AdminUser | null>(null);

  const client = useMemo(
    () =>
      createApiClient({
        baseUrl: defaultApiBaseUrl(),
        // Firebase is the only token source: every protected call carries the
        // administrator's current ID token, plus an App Check token when this
        // build has one (the API verifies it; the browser does not vouch for it).
        getToken: () => currentIdToken(),
        getAppCheckToken: () => currentAppCheckToken(),
      }),
    [],
  );

  const refresh = useCallback(async () => {
    const user = firebaseAuth()?.currentUser ?? null;
    if (user) {
      setAdmin({ uid: user.uid, email: user.email ?? null });
      setStatus("authenticated");
    } else {
      setAdmin(null);
      setStatus("unauthenticated");
    }
  }, []);

  useEffect(() => {
    if (!isFirebaseConfigured) {
      setAdmin(null);
      setStatus("unauthenticated");
      return;
    }

    return subscribeToAuth((user) => {
      if (user) {
        setAdmin({ uid: user.uid, email: user.email ?? null });
        setStatus("authenticated");
      } else {
        setAdmin(null);
        setStatus("unauthenticated");
      }
    });
  }, []);

  const signOut = useCallback(async () => {
    await signOutAdmin();
    setAdmin(null);
    setStatus("unauthenticated");
  }, []);

  const value = useMemo<SessionValue>(
    () => ({ status, admin, client, signOut, refresh }),
    [status, admin, client, signOut, refresh],
  );

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}
