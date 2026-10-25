/**
 * What the owner typed -> the strings the event form already holds
 * ("YYYY-MM-DD", "HH:mm"). Pure string work: no Date arithmetic of its own, no
 * time zone. The zone-dependent step stays where it was (formInstant /
 * utils/datetime), and this module cannot reach it.
 *
 * Parsing happens on COMMIT (blur / Enter), never per keystroke, so a value
 * that is half-typed is never rewritten under the owner's cursor. Nothing here
 * CORRECTS a value: an impossible date or time is refused with a reason, never
 * rolled over into a neighbouring one. Ported from the P8-b5.6b-1 prototype
 * (prototypes/datetime-picker), where the owner tried and approved it.
 */

/** Full-width digits and separators an IME produces (「１４：３０」「２０２６／１０／１８」). */
export function toAsciiDigits(s: string): string {
  return s
    .replace(/[０-９]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xfee0))
    .replace(/[：]/g, ':')
    .replace(/[．。]/g, '.')
    .replace(/[／]/g, '/')
    .replace(/[－ー−]/g, '-')
    .replace(/\s+/g, '');
}

const pad2 = (n: number) => String(n).padStart(2, '0');

/*
  The kanji an IME leaves in a typed date or time (年 月 日 時 分), written as
  escapes: src/i18n/appUi.i18n.test.ts refuses Japanese inside string-like
  spans outside the dictionary, and these are input syntax, not UI copy.
*/
const KANJI_YEAR_MONTH = /年|月/g; // 年 月
const KANJI_DAY_END = /日$/; // 日
const KANJI_HOUR = /時/; // 時
const KANJI_MINUTE_END = /分$/; // 分

export type TimeTextError = 'empty' | 'format' | 'hourRange' | 'minuteRange' | 'ambiguous';
export type DateTextError = 'empty' | 'format' | 'nonexistent';
export type Parsed<E> = { ok: true; value: string } | { ok: false; reason: E };

/**
 * "14:30" "1430" "930" "9:30" "14" "14時30分" "14.30" -> "HH:mm".
 *
 * Refused, never corrected:
 *  - "24:00" "25:00" -> hourRange. The app pins hourCycle h23 (CLOCK_24H); the
 *    next midnight is 00:00 on the next day.
 *  - "14:78"         -> minuteRange, not 15:18.
 *  - "9:5"           -> ambiguous: 09:05 or 09:50?
 */
export function parseTimeText(raw: string): Parsed<TimeTextError> {
  const s = toAsciiDigits(raw).replace(KANJI_MINUTE_END, '').replace(KANJI_HOUR, ':');
  if (s === '') return { ok: false, reason: 'empty' };
  let h: number;
  let m: number;
  let match: RegExpMatchArray | null;
  if ((match = s.match(/^(\d{1,2})[:.](\d{1,2})?$/))) {
    h = Number(match[1]);
    m = match[2] === undefined ? 0 : Number(match[2]);
    if (match[2] !== undefined && match[2].length === 1) return { ok: false, reason: 'ambiguous' };
  } else if ((match = s.match(/^(\d{3,4})$/))) {
    const digits = match[1]!;
    h = Number(digits.slice(0, -2));
    m = Number(digits.slice(-2));
  } else if ((match = s.match(/^(\d{1,2})$/))) {
    h = Number(match[1]);
    m = 0;
  } else {
    return { ok: false, reason: 'format' };
  }
  if (h > 23) return { ok: false, reason: 'hourRange' };
  if (m > 59) return { ok: false, reason: 'minuteRange' };
  return { ok: true, value: `${pad2(h)}:${pad2(m)}` };
}

/** A real calendar date, checked by a Date.UTC round trip (no arithmetic of our own). */
export function isRealDate(y: number, mo: number, d: number): boolean {
  if (y < 1000 || y > 9999 || mo < 1 || mo > 12 || d < 1 || d > 31) return false;
  const t = new Date(Date.UTC(y, mo - 1, d));
  return t.getUTCFullYear() === y && t.getUTCMonth() === mo - 1 && t.getUTCDate() === d;
}

/**
 * "20261019" "2026-10-19" "2026/10/19" "2026年10月19日" "2026-1-9" -> "YYYY-MM-DD".
 * "10/19" borrows `fallbackYear` (the field's committed year).
 * "20260230" is `nonexistent`, never 2026-03-02.
 */
export function parseDateText(raw: string, fallbackYear?: number): Parsed<DateTextError> {
  const s = toAsciiDigits(raw).replace(KANJI_YEAR_MONTH, '/').replace(KANJI_DAY_END, '').replace(/[.-]/g, '/');
  if (s === '') return { ok: false, reason: 'empty' };
  let y: number;
  let mo: number;
  let d: number;
  let match: RegExpMatchArray | null;
  if ((match = s.match(/^(\d{4})\/(\d{1,2})\/(\d{1,2})$/))) {
    [y, mo, d] = [Number(match[1]), Number(match[2]), Number(match[3])];
  } else if ((match = s.match(/^(\d{4})(\d{2})(\d{2})$/))) {
    [y, mo, d] = [Number(match[1]), Number(match[2]), Number(match[3])];
  } else if (fallbackYear && (match = s.match(/^(\d{1,2})\/(\d{1,2})$/))) {
    [y, mo, d] = [fallbackYear, Number(match[1]), Number(match[2])];
  } else {
    return { ok: false, reason: 'format' };
  }
  if (!isRealDate(y, mo, d)) return { ok: false, reason: 'nonexistent' };
  return { ok: true, value: `${y}-${pad2(mo)}-${pad2(d)}` };
}

/** Step one segment of a committed "HH:mm" without carrying into the other (like native segments). */
export function stepTime(hhmm: string, part: 'hour' | 'minute', delta: number): string {
  const [h, m] = hhmm.split(':').map(Number) as [number, number];
  if (part === 'hour') return `${pad2((((h + delta) % 24) + 24) % 24)}:${pad2(m)}`;
  return `${pad2(h)}:${pad2((((m + delta) % 60) + 60) % 60)}`;
}

// ---- the faint format guide ------------------------------------------------

/**
 * Templates the guide can follow. Letters are digit slots, anything else is a
 * literal the owner typed. The first template the draft is a prefix of wins,
 * so "2026" is guided as "-MM-DD" (the canonical form), while "20261" -- which
 * can only be the compact form -- is guided as "MDD".
 */
export const DATE_TEMPLATES = ['YYYY-MM-DD', 'YYYY/MM/DD', 'YYYYMMDD'] as const;
export const TIME_TEMPLATES = ['HH:mm', 'H:mm', 'HHmm'] as const;

/**
 * The rest of the template after `draft`, or null when the draft follows no
 * template (then nothing is drawn -- the guide never guesses). Full-width
 * digits count as digits, so an IME-typed draft is guided the same way.
 */
export function guideRemainder(draft: string, templates: readonly string[]): string | null {
  const s = draft.replace(/[０-９]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xfee0));
  if (s === '') return null;
  for (const t of templates) {
    if (s.length >= t.length) continue;
    let ok = true;
    for (let i = 0; i < s.length; i++) {
      const slot = t[i]!;
      const isDigitSlot = /[A-Za-z]/.test(slot);
      if (isDigitSlot ? !/\d/.test(s[i]!) : s[i] !== slot) {
        ok = false;
        break;
      }
    }
    if (ok) return t.slice(s.length);
  }
  return null;
}

/**
 * The date field's automatic hyphen (on by default since P8-b5.6b-2, after the
 * owner tried both). It acts on ONE case: a digit typed at the END that makes
 * "YYYY" or "YYYY-MM" turns it into "YYYY-" / "YYYY-MM-". It never touches a
 * deletion, a paste, an edit in the middle or a draft that uses "/", and a "-"
 * typed right after an inserted one is swallowed, so typing the hyphen by hand
 * still works.
 *
 * Returns the replacement draft, or null to accept the browser's value as is.
 */
export function autoHyphen(prev: string, next: string, inputType: string, caretAtEnd: boolean): string | null {
  if (inputType !== 'insertText' || !caretAtEnd) return null;
  if (next === `${prev}-` && /^\d{4}-$|^\d{4}-\d{2}-$/.test(prev)) return prev; // the owner's own "-"
  if (next.length !== prev.length + 1 || !next.startsWith(prev)) return null;
  if (/^\d{4}$/.test(next) || /^\d{4}-\d{2}$/.test(next)) return `${next}-`;
  return null;
}
