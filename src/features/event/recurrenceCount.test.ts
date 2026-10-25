import { describe, expect, it } from 'vitest';
import { formToRule, EMPTY_RECURRENCE_FORM, RecurrenceFormError, type RecurrenceForm } from './recurrenceForm';
import * as recurrenceForm from './recurrenceForm';
import * as recurrence from '../../services/recurrence';
import { expandRule, formatRRule, parseRRule } from '../../services/recurrence';

/*
  K14 (P8-finish-3a.2): the repeat COUNT had the same defect K13 fixed for the
  interval -- parseInt read "1e21" / "1.5" / "12abc" as 1 / 1 / 12, a long digit
  string became 1e+23 and was saved as "COUNT=1e+23", and nothing bounded it,
  although the server's parser (0006 rrule_parse) takes COUNT only as
  ^[1-9][0-9]{0,6}$ (1..9,999,999). Same rule as K13: digits only, the server's
  range, nothing rounded or clamped, an invalid value refused with its own
  message. Reading stored rules is unchanged.
*/

const MON = '2026-06-01T00:00:00.000Z';
const TZ = 'Asia/Tokyo';
const form = (over: Partial<RecurrenceForm>): RecurrenceForm => ({ ...EMPTY_RECURRENCE_FORM, freq: 'daily', endMode: 'count', ...over });
const reasonOf = (f: RecurrenceForm): string | null => {
  try {
    formToRule(f, MON, TZ, false);
    return null;
  } catch (e) {
    return e instanceof RecurrenceFormError ? e.reason : `other:${String(e)}`;
  }
};
const SQL_COUNT = /^[1-9][0-9]{0,6}$/;

describe('K14: the count the app saves is one the server reads', () => {
  it("the bound is exported and is the server's", () => {
    expect((recurrence as Record<string, unknown>).MAX_COUNT).toBe(9_999_999);
  });

  it.each([1, 2, 10, 365, 9_999_998, 9_999_999])('%d is accepted and written as plain digits', (n) => {
    for (const freq of ['daily', 'weekly', 'monthly'] as const) {
      const text = formatRRule(formToRule(form({ freq, count: n }), MON, TZ, false)!);
      expect(/COUNT=([^;]*)/.exec(text)![1]).toMatch(SQL_COUNT);
      expect(parseRRule(text).count).toBe(n);
    }
  });

  it.each([10_000_000, 10_000_001, Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER + 2, 1e21, 1e23, Number.MAX_VALUE])(
    '%d is refused on save, never clamped',
    (n) => {
      expect(reasonOf(form({ count: n }))).toBe('countInvalid');
    },
  );

  it.each([1.5, 2.25, 9_999_998.5, NaN, Infinity])('%d is refused, never floored', (n) => {
    expect(reasonOf(form({ count: n }))).toBe('countInvalid');
  });

  it.each([0, 0.5, -1, -Infinity])('%d keeps the existing "1 or more" reason', (n) => {
    expect(reasonOf(form({ count: n }))).toBe('countTooSmall');
  });

  it('the count is only checked when the series ends by count (as before)', () => {
    expect(reasonOf(form({ endMode: 'never', count: 1e23 }))).toBeNull();
  });

  it('the new reason reads in both languages and names the range', () => {
    const e = new RecurrenceFormError('countInvalid' as never);
    expect(e.localize('ja')).toContain('9,999,999');
    expect(e.localize('en')).toContain('9,999,999');
    expect(e.localize('en')).not.toMatch(/[぀-ヿ一-鿿]/);
  });

  it('formatRRule itself refuses a count outside 1..9,999,999', () => {
    for (const count of [0, 10_000_000, 1e23, 1.5, NaN]) {
      expect(() => formatRRule({ freq: 'DAILY', interval: 1, count }), String(count)).toThrow();
    }
  });
});

describe('K14: what is typed into the count field', () => {
  type Parsed = { display: string; commit: number | null };
  const parse = (recurrenceForm as Record<string, unknown>).parseCountInput as ((raw: string, badInput?: boolean) => Parsed) | undefined;
  const p = (raw: string, badInput = false): Parsed => {
    if (!parse) throw new Error('parseCountInput is not exported');
    return parse(raw, badInput);
  };

  it.each([
    ['1', 1, '1'],
    ['10', 10, '10'],
    ['007', 7, '7'],
    ['9999999', 9_999_999, '9999999'],
  ])('%j is committed as %d', (raw, n, display) => {
    expect(p(raw)).toEqual({ display, commit: n });
  });

  it('an empty field keeps the previous value while typing, as before', () => {
    expect(p('')).toEqual({ display: '', commit: null });
  });

  it.each(['1e21', '1e3', '1.5', '12abc', '0x10', '-3', '+5', 'NaN', 'Infinity', '１２'])('%j is not partially read: committed as invalid, shown as typed', (raw) => {
    const r = p(raw);
    expect(r.display).toBe(raw);
    expect(r.commit).not.toBeNull();
    expect(reasonOf(form({ count: r.commit! }))).not.toBeNull();
  });

  it.each(['10000000', '9007199254740993', '100000000000000000000000'])('%j stays as typed and is refused as out of range', (raw) => {
    const r = p(raw);
    expect(r.display).toBe(raw);
    expect(reasonOf(form({ count: r.commit! }))).toBe('countInvalid');
  });

  it('badInput is invalid, not empty', () => {
    expect(reasonOf(form({ count: p('', true).commit! }))).toBe('countInvalid');
  });
});

describe('K14: the editor uses the strict reader for the count', () => {
  const editor = ((import.meta.glob('/src/features/event/RecurrenceEditor.tsx', { query: '?raw', import: 'default', eager: true }) as Record<string, string>)[
    '/src/features/event/RecurrenceEditor.tsx'
  ] ?? '').replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

  it('the count field is read by parseCountInput with badInput, bounded 1..MAX_COUNT', () => {
    expect(editor).toMatch(/onChange=\{\(e\) => changeCount\(e\.target\.value, e\.target\.validity\.badInput\)\}/);
    expect(editor).toMatch(/const \{ display, commit \} = parseCountInput\(raw, badInput\);/);
    expect(editor).toMatch(/max=\{MAX_COUNT\}/);
  });
});

describe('K14: a legal but very large COUNT stays cheap to expand', () => {
  // Parsing succeeding and expansion being cheap are separate claims. DAILY and
  // WEEKLY compute the occurrences in the window in closed form, so COUNT only
  // caps the index; MONTHLY walks at most MAX_ITERATIONS months.
  it.each(['DAILY', 'WEEKLY', 'MONTHLY'])('FREQ=%s;COUNT=9999999 over a year window', (freq) => {
    const t0 = performance.now();
    const starts = expandRule(`FREQ=${freq};COUNT=9999999`, '2026-01-05T01:00:00.000Z', '2026-01-01T00:00:00.000Z', '2027-01-01T00:00:00.000Z', freq === 'MONTHLY' ? null : TZ);
    const ms = performance.now() - t0;
    expect(starts.length).toBe(freq === 'DAILY' ? 361 : freq === 'WEEKLY' ? 52 : 12);
    expect(ms).toBeLessThan(500);
  });

  it('a window far into a 9,999,999-day series is still closed-form (no walk from DTSTART)', () => {
    const t0 = performance.now();
    const starts = expandRule('FREQ=DAILY;COUNT=9999999', '2026-01-05T01:00:00.000Z', '9000-01-01T00:00:00.000Z', '9000-01-08T00:00:00.000Z', TZ);
    expect(starts.length).toBe(7);
    expect(performance.now() - t0).toBeLessThan(500);
  });
});

describe('K17: the last end date a timed series can carry', () => {
  // The end of a timed series is the end of that day in the series' zone, which
  // is computed through the NEXT day. For 9999-12-31 that is 10000-01-01, which
  // the date code cannot represent: the save failed with the raw English
  // "Invalid time value". The date field itself accepts years 1000..9999.
  const until = (untilDate: string, allDay: boolean, tz = TZ) => {
    try {
      return formToRule(form({ endMode: 'until', untilDate }), MON, tz, allDay)!.until;
    } catch (e) {
      return e instanceof RecurrenceFormError ? e.reason : `other:${(e as Error).name}`;
    }
  };

  it.each(['Asia/Tokyo', 'America/New_York', 'Pacific/Kiritimati', 'Pacific/Pago_Pago', 'UTC'])('9999-12-31 on a timed series (%s) is refused with a message, not a raw error', (tz) => {
    expect(until('9999-12-31', false, tz)).toBe('untilOutOfRange');
  });

  it('9999-12-30 on a timed series is the last one kept, as the end of that day', () => {
    expect(until('9999-12-30', false)).toEqual({ kind: 'instant', instant: '9999-12-30T14:59:59.999Z' });
  });

  it('an all-day series keeps 9999-12-31 as a date (no instant is computed)', () => {
    expect(until('9999-12-31', true)).toEqual({ kind: 'date', date: '9999-12-31' });
  });

  it('the new reason reads in both languages', () => {
    const e = new RecurrenceFormError('untilOutOfRange' as never);
    expect(e.localize('ja')).toContain('9999');
    expect(e.localize('en')).toContain('9999');
    expect(e.localize('en')).not.toMatch(/[぀-ヿ一-鿿]/);
  });
});
