import { describe, expect, it } from 'vitest';
import {
  DATE_TEMPLATES, TIME_TEMPLATES, autoHyphen, guideRemainder, parseDateText, parseTimeText, stepTime,
} from './dateTimeText';
import { addMonthsClamped, daysInMonth, monthGrid } from './calendarMonth';
import { hourAt, hourPos, minuteAt, minutePos, xy } from './clockGeometry';

const ok = (value: string) => ({ ok: true, value });
const no = (reason: string) => ({ ok: false, reason });

describe('time text', () => {
  it.each([
    ['1430', '14:30'], ['14:30', '14:30'], ['930', '09:30'], ['9:30', '09:30'], ['0930', '09:30'],
    ['14', '14:00'], ['14:', '14:00'], ['１４：３０', '14:30'], ['14時30分', '14:30'], ['14.45', '14:45'],
    ['0:00', '00:00'], ['0000', '00:00'], ['23:59', '23:59'], ['2359', '23:59'], ['14:37', '14:37'],
  ])('%s -> %s', (input, out) => {
    expect(parseTimeText(input)).toEqual(ok(out));
  });

  it.each([
    ['', 'empty'], ['24:00', 'hourRange'], ['2400', 'hourRange'], ['25:00', 'hourRange'],
    ['14:78', 'minuteRange'], ['1478', 'minuteRange'], ['14:60', 'minuteRange'],
    ['9:5', 'ambiguous'], ['abc', 'format'], ['12345', 'format'], ['1:2:3', 'format'],
  ])('%s is refused (%s), never corrected', (input, reason) => {
    expect(parseTimeText(input)).toEqual(no(reason));
  });

  it('steps one segment without carrying', () => {
    expect(stepTime('23:59', 'minute', 1)).toBe('23:00');
    expect(stepTime('23:59', 'hour', 1)).toBe('00:59');
    expect(stepTime('00:00', 'minute', -1)).toBe('00:59');
  });
});

describe('date text', () => {
  it.each([
    ['20261019', '2026-10-19'], ['2026-10-19', '2026-10-19'], ['2026/10/19', '2026-10-19'],
    ['2026-1-9', '2026-01-09'], ['２０２６１０１９', '2026-10-19'], ['2026年10月19日', '2026-10-19'],
    ['10/19', '2026-10-19'], ['20280229', '2028-02-29'], ['20261231', '2026-12-31'], ['20270101', '2027-01-01'],
  ])('%s -> %s', (input, out) => {
    expect(parseDateText(input, 2026)).toEqual(ok(out));
  });

  it.each(['20260230', '2026-02-29', '2026-13-01', '2026-00-10', '2026-04-31', '20261032', '21000229'])(
    '%s does not exist and is refused, not rolled over',
    (input) => {
      expect(parseDateText(input, 2026)).toEqual(no('nonexistent'));
    },
  );

  it.each([['', 'empty'], ['2026101', 'format'], ['2026-10', 'format'], ['x', 'format'], ['202610199', 'format']])(
    '%s is refused (%s)',
    (input, reason) => {
      expect(parseDateText(input, 2026)).toEqual(no(reason));
    },
  );
});

describe('the faint format guide', () => {
  it('follows the style being typed', () => {
    expect(guideRemainder('2026', DATE_TEMPLATES)).toBe('-MM-DD');
    expect(guideRemainder('2026-', DATE_TEMPLATES)).toBe('MM-DD');
    expect(guideRemainder('2026-1', DATE_TEMPLATES)).toBe('M-DD');
    expect(guideRemainder('2026/10', DATE_TEMPLATES)).toBe('/DD');
    expect(guideRemainder('20261', DATE_TEMPLATES)).toBe('MDD');
    expect(guideRemainder('2026101', DATE_TEMPLATES)).toBe('D');
    expect(guideRemainder('14', TIME_TEMPLATES)).toBe(':mm');
    expect(guideRemainder('9:', TIME_TEMPLATES)).toBe('mm');
    expect(guideRemainder('143', TIME_TEMPLATES)).toBe('m');
    expect(guideRemainder('１４', TIME_TEMPLATES)).toBe(':mm');
  });

  it('draws nothing when complete, empty or off-template (it never guesses)', () => {
    expect(guideRemainder('20261019', DATE_TEMPLATES)).toBeNull();
    expect(guideRemainder('2026-10-19', DATE_TEMPLATES)).toBeNull();
    expect(guideRemainder('', DATE_TEMPLATES)).toBeNull();
    expect(guideRemainder('20x6', DATE_TEMPLATES)).toBeNull();
    expect(guideRemainder('14:30', TIME_TEMPLATES)).toBeNull();
  });
});

describe('automatic hyphen', () => {
  it('acts only on a digit typed at the end', () => {
    expect(autoHyphen('202', '2026', 'insertText', true)).toBe('2026-');
    expect(autoHyphen('2026-1', '2026-10', 'insertText', true)).toBe('2026-10-');
  });

  it('accepts a hyphen typed by hand, without doubling it', () => {
    expect(autoHyphen('2026-', '2026--', 'insertText', true)).toBe('2026-');
    expect(autoHyphen('2026-10-', '2026-10--', 'insertText', true)).toBe('2026-10-');
  });

  it('leaves deletion, middle edits, paste and slashes alone', () => {
    expect(autoHyphen('2026-', '2026', 'deleteContentBackward', true)).toBeNull();
    expect(autoHyphen('202', '2026', 'insertText', false)).toBeNull();
    expect(autoHyphen('', '20261019', 'insertFromPaste', true)).toBeNull();
    expect(autoHyphen('2026/1', '2026/10', 'insertText', true)).toBeNull();
    expect(autoHyphen('2026101', '20261019', 'insertText', true)).toBeNull();
  });
});

describe('month grid', () => {
  it('starts weeks on Monday', () => {
    const g = monthGrid(2026, 10);
    expect(g).toHaveLength(42);
    expect(g[0]!.key).toBe('2026-09-28');
    expect(g.find((c) => c.inMonth)!.key).toBe('2026-10-01');
    expect(g.filter((c) => c.inMonth)).toHaveLength(31);
  });

  it('handles leap years and clamps month steps instead of rolling over', () => {
    expect(daysInMonth(2028, 2)).toBe(29);
    expect(daysInMonth(2026, 2)).toBe(28);
    expect(daysInMonth(2100, 2)).toBe(28);
    expect(addMonthsClamped('2026-01-31', 1)).toBe('2026-02-28');
    expect(addMonthsClamped('2028-01-31', 1)).toBe('2028-02-29');
    expect(addMonthsClamped('2026-12-15', 1)).toBe('2027-01-15');
    expect(addMonthsClamped('2026-01-15', -1)).toBe('2025-12-15');
    expect(addMonthsClamped('2028-02-29', 12)).toBe('2029-02-28');
  });
});

describe('clock geometry', () => {
  it('round-trips every hour and minute through a point on the dial', () => {
    for (let h = 0; h < 24; h++) {
      const { x, y } = xy(hourPos(h));
      expect(hourAt(x, y)).toBe(h);
    }
    for (let m = 0; m < 60; m++) {
      const { x, y } = xy(minutePos(m));
      expect(minuteAt(x, y)).toBe(m);
    }
  });
});
