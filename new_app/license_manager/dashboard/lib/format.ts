/** Presentation helpers. No business logic lives here. */

const DATE_TIME = new Intl.DateTimeFormat(undefined, {
  dateStyle: "medium",
  timeStyle: "short",
});

const DATE_ONLY = new Intl.DateTimeFormat(undefined, { dateStyle: "medium" });

export function formatDateTime(value?: string | null): string {
  if (!value) return "—";
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return "—";
  return DATE_TIME.format(parsed);
}

export function formatDate(value?: string | null): string {
  if (!value) return "—";
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return "—";
  return DATE_ONLY.format(parsed);
}

export function relativeTime(value?: string | null): string {
  if (!value) return "—";
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return "—";
  const diffSeconds = Math.round((parsed.getTime() - Date.now()) / 1000);
  const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  const units: Array<[Intl.RelativeTimeFormatUnit, number]> = [
    ["day", 86400],
    ["hour", 3600],
    ["minute", 60],
  ];
  for (const [unit, seconds] of units) {
    if (Math.abs(diffSeconds) >= seconds) {
      return formatter.format(Math.round(diffSeconds / seconds), unit);
    }
  }
  return "just now";
}

/** Short, reversible display for a 64-hex digest: `a1b2c3d4…9f0e`. */
export function shortHash(value?: string | null, size = 10): string {
  if (!value) return "—";
  if (value.length <= size * 2) return value;
  return `${value.slice(0, size)}…${value.slice(-4)}`;
}

export function truncate(value?: string | null, max = 40): string {
  if (!value) return "—";
  return value.length <= max ? value : `${value.slice(0, max - 1)}…`;
}

const STATUS_LABELS: Record<string, string> = {
  active: "Active",
  superseded: "Superseded",
  revoked: "Revoked",
};

export function statusLabel(status?: string | null): string {
  if (!status) return "Unknown";
  return STATUS_LABELS[status] ?? titleCase(status);
}

export function titleCase(value: string): string {
  return value
    .replace(/[_-]+/g, " ")
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}

export function initials(value?: string | null): string {
  if (!value) return "A";
  const parts = value.trim().split(/\s+/).slice(0, 2);
  const letters = parts.map((part) => part.charAt(0).toUpperCase()).join("");
  return letters || "A";
}

export function plural(count: number, singular: string, pluralForm?: string): string {
  return `${count} ${count === 1 ? singular : (pluralForm ?? `${singular}s`)}`;
}
