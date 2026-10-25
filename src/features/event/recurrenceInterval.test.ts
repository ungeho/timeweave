import { describe, expect, it } from 'vitest';
import { formToRule, EMPTY_RECURRENCE_FORM, RecurrenceFormError, type RecurrenceForm } from './recurrenceForm';
import * as recurrenceForm from './recurrenceForm';
import * as recurrence from '../../services/recurrence';
import { formatRRule, parseRRule } from '../../services/recurrence';

/*
  K13 (P8-finish-3a.1): the repeat INTERVAL had no upper bound and was read
  leniently, so
    - a long digit string reached the rule as 1e+23 and was saved as
      "INTERVAL=1e+23" (a WEEKLY timed series then throws when expanded and is
      hidden by K12's isolation right after it was saved);
    - "1e21", "1.5" and "12abc" were silently read as 1, 1 and 12;
    - 10000 and above were saved although the server's parser (0006
      rrule_parse, ^[1-9][0-9]{0,3}$) treats them as malformed, so the share
      page answered "could not be determined" for the series.
  The bound is the server's: 1..9999, digits only. Nothing is rounded or
  clamped; an invalid value is refused on save with its own message.
*/

const MON = '2026-06-01T00:00:00.000Z';
const TZ = 'Asia/Tokyo';
const form = (over: Partial<RecurrenceForm>): RecurrenceForm => ({ ...EMPTY_RECURRENCE_FORM, freq: 'daily', ...over });
const reasonOf = (f: RecurrenceForm): string | null => {
  try {
    formToRule(f, MON, TZ, false);
    return null;
  } catch (e) {
    return e instanceof RecurrenceFormError ? e.reason : `other:${String(e)}`;
  }
};
/** The server's own INTERVAL syntax (supabase/migrations/0006_rrule_parser.sql). */
const SQL_INTERVAL = /^[1-9][0-9]{0,3}$/;

describe('K13: the interval the app saves is one the server reads', () => {
  it('the bound is exported and is the server\'s', () => {
    expect((recurrence as Record<string, unknown>).MAX_INTERVAL).toBe(9999);
  });

  it.each([1, 2, 7, 52, 999, 9998, 9999])('%d is accepted and written as plain digits the server accepts', (n) => {
    for (const freq of ['daily', 'weekly', 'monthly'] as const) {
      const rule = formToRule(form({ freq, interval: n }), MON, TZ, false)!;
      const text = formatRRule(rule);
      const m = /INTERVAL=([^;]*)/.exec(text);
      if (n === 1) expect(m).toBeNull();
      else expect(m![1]).toMatch(SQL_INTERVAL);
      expect(parseRRule(text).interval).toBe(n);
    }
  });

  it.each([10000, 10001, 99999, Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER + 2, 1e21, 1e23, Number.MAX_VALUE])(
    '%d is refused on save, never rounded or clamped',
    (n) => {
      expect(reasonOf(form({ interval: n }))).toBe('intervalInvalid');
    },
  );

  it.each([1.5, 2.25, 9998.5])('a fraction (%d) is refused, not floored', (n) => {
    expect(reasonOf(form({ interval: n }))).toBe('intervalInvalid');
  });

  it.each([NaN, Infinity])('%d is refused as not a number in range', (n) => {
    expect(reasonOf(form({ interval: n }))).toBe('intervalInvalid');
  });

  it.each([0, 0.5, -1, -Infinity])('%d keeps the existing "1 or more" reason', (n) => {
    expect(reasonOf(form({ interval: n }))).toBe('intervalTooSmall');
  });

  it('the two reasons read in both languages, and the new one names the range', () => {
    const e = new RecurrenceFormError('intervalInvalid' as never);
    expect(e.localize('ja')).toContain('9999');
    expect(e.localize('en')).toContain('9999');
    expect(e.localize('en')).not.toMatch(/[぀-ヿ一-鿿]/);
  });

  it('formatRRule itself refuses an interval outside 1..9999 (the last step before the database)', () => {
    for (const interval of [0, 10000, 1e23, 1.5, NaN]) {
      expect(() => formatRRule({ freq: 'DAILY', interval }), String(interval)).toThrow();
    }
  });
});

describe('K13: what is typed into the interval field', () => {
  type Parsed = { display: string; commit: number | null };
  const parse = (recurrenceForm as Record<string, unknown>).parseIntervalInput as
    | ((raw: string, badInput?: boolean) => Parsed)
    | undefined;
  const p = (raw: string, badInput = false): Parsed => {
    if (!parse) throw new Error('parseIntervalInput is not exported');
    return parse(raw, badInput);
  };

  it.each([
    ['1', 1, '1'],
    ['7', 7, '7'],
    ['05', 5, '5'],
    [' 12 ', 12, '12'],
    ['9999', 9999, '9999'],
  ])('%j is committed as %d', (raw, n, display) => {
    expect(p(raw)).toEqual({ display, commit: n });
  });

  it('an empty field (mid-edit) keeps the previous value, as before', () => {
    expect(p('')).toEqual({ display: '', commit: null });
    expect(p('   ')).toEqual({ display: '', commit: null });
  });

  it.each(['1e21', '1e3', '1.5', '12abc', '0x10', '-3', '+5', 'NaN', 'Infinity', '１２'])(
    '%j is NOT partially read: it is committed as invalid and shown as typed',
    (raw) => {
      const r = p(raw);
      expect(r.display).toBe(raw);
      expect(r.commit).not.toBeNull(); // never "keep the previous value"
      expect(reasonOf(form({ interval: r.commit! }))).not.toBeNull(); // and never savable
    },
  );

  it.each(['0', '00'])('%j is committed as 0 and refused as "1 or more"', (raw) => {
    expect(p(raw).commit).toBe(0);
    expect(reasonOf(form({ interval: p(raw).commit! }))).toBe('intervalTooSmall');
  });

  it.each(['10000', '9007199254740993', '100000000000000000000000'])('%j stays as typed and is refused as out of range', (raw) => {
    const r = p(raw);
    expect(r.display).toBe(raw);
    expect(reasonOf(form({ interval: r.commit! }))).toBe('intervalInvalid');
  });

  it('text the browser could not read as a number (validity.badInput) is invalid, not "empty"', () => {
    const r = p('', true);
    expect(r.commit).not.toBeNull();
    expect(reasonOf(form({ interval: r.commit! }))).toBe('intervalInvalid');
  });
});

describe('K13: the editor uses the strict reader for the interval', () => {
  const editor = ((import.meta.glob('/src/features/event/RecurrenceEditor.tsx', { query: '?raw', import: 'default', eager: true }) as Record<string, string>)[
    '/src/features/event/RecurrenceEditor.tsx'
  ] ?? '').replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

  it('the interval field is read by parseIntervalInput (with badInput), bounded 1..MAX_INTERVAL', () => {
    expect(editor).toMatch(/onChange=\{\(e\) => changeInterval\(e\.target\.value, e\.target\.validity\.badInput\)\}/);
    expect(editor).toMatch(/const changeInterval = \(raw: string, badInput: boolean\) => \{\s*const \{ display, commit \} = parseIntervalInput\(raw, badInput\);/);
    // the count field was untouched by K13; K14 gave it its own strict reader
    // with its own bound (recurrenceCount.test.ts), so the two never share one
    expect(editor).toMatch(/const changeCount = \(raw: string, badInput: boolean\) => \{\s*const \{ display, commit \} = parseCountInput\(raw, badInput\);/);
    expect(editor).toMatch(/max=\{MAX_INTERVAL\}/);
  });
});

describe('K13: rows already stored with an out-of-range interval', () => {
  // Reading is NOT narrowed: such a row still opens, and is refused only when
  // saved again -- the owner sees the message and can correct the value.
  const ruleToFormLoaded = (text: string) => recurrenceForm.ruleToForm(parseRRule(text), TZ);

  it.each(['FREQ=DAILY;INTERVAL=10000', 'FREQ=MONTHLY;INTERVAL=1e+23'])(
    '%s still reads, and saving it again is refused with the new reason',
    (text) => {
      const f = ruleToFormLoaded(text);
      expect(reasonOf(f)).toBe('intervalInvalid');
    },
  );

  it('an in-range value stored in another notation (INTERVAL=1e3) is saved back as plain digits', () => {
    const f = ruleToFormLoaded('FREQ=WEEKLY;INTERVAL=1e3');
    expect(f.interval).toBe(1000);
    expect(formatRRule(formToRule(f, MON, TZ, false)!)).toMatch(/INTERVAL=1000(;|$)/);
  });

  it('a weekly timed series stored as INTERVAL=1e+23 is the K12 case: isolated and counted, the rest drawn', async () => {
    const { expandEventsWithIssues, unexpandableMasters } = await import('../../services/occurrences');
    const base = {
      ownerId: 'o', title: 't', description: null, category: null, visibility: 'public' as const, availability: 'busy' as const,
      allDay: false, startDate: null, endDate: null, recurrenceId: null, recurrenceSlotStart: null, recurrenceSlotDate: null,
      isCancelled: false, timezone: 'Asia/Tokyo', createdAt: '', updatedAt: '',
    };
    const bad = { ...base, id: 'bad', startAt: '2026-06-02T01:00:00.000Z', endAt: '2026-06-02T02:00:00.000Z', rrule: 'FREQ=WEEKLY;INTERVAL=1e+23' };
    const good = { ...base, id: 'good', startAt: '2026-06-02T03:00:00.000Z', endAt: '2026-06-02T04:00:00.000Z', rrule: 'FREQ=WEEKLY;INTERVAL=2' };
    const res = expandEventsWithIssues([bad, good], '2026-06-01T00:00:00.000Z', '2026-06-30T00:00:00.000Z');
    expect(res.occurrences.map((o) => `${o.event.id} ${o.start}`)).toEqual([
      'good 2026-06-02T03:00:00.000Z',
      'good 2026-06-16T03:00:00.000Z',
    ]);
    expect(res.unexpandable.map((r) => r.id)).toEqual(['bad']);
    expect(unexpandableMasters([bad, good]).map((r) => r.id)).toEqual(['bad']);
  });
});
