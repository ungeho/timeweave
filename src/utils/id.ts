/** Generate a random UUID. Wrapped so the source is swappable if needed. */
export function newId(): string {
  return crypto.randomUUID();
}
