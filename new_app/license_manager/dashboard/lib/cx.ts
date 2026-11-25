export type ClassValue = string | false | null | undefined;

/** Minimal class joiner (no runtime dependency needed). */
export function cx(...values: ClassValue[]): string {
  return values.filter(Boolean).join(" ");
}
