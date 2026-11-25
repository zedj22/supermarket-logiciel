"use client";

import { useCallback, useEffect, useState } from "react";

import { errorMessage, type ApiClient } from "./api";
import { useSession } from "./session";

export interface Resource<T> {
  data: T | null;
  error: string | null;
  loading: boolean;
  reload: () => void;
}

/**
 * Fetch one API resource and keep its loading/error state.
 *
 * `loader` must be stable (module-level or wrapped in useCallback); the effect
 * re-runs when `deps` change, which is how search boxes reload.
 */
export function useResource<T>(
  loader: (client: ApiClient) => Promise<T>,
  deps: unknown[] = [],
): Resource<T> {
  const { client } = useSession();
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [nonce, setNonce] = useState(0);

  const reload = useCallback(() => setNonce((value) => value + 1), []);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    loader(client)
      .then((value) => {
        if (!cancelled) {
          setData(value);
          setLoading(false);
        }
      })
      .catch((cause: unknown) => {
        if (!cancelled) {
          setData(null);
          setError(errorMessage(cause));
          setLoading(false);
        }
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [client, loader, nonce, ...deps]);

  return { data, error, loading, reload };
}

/** Debounce a value (used by the search inputs). */
export function useDebounced<T>(value: T, delay = 250): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const timer = window.setTimeout(() => setDebounced(value), delay);
    return () => window.clearTimeout(timer);
  }, [value, delay]);
  return debounced;
}
