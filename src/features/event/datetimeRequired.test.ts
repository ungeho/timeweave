/**
 * What an emptied date input must not be able to do.
 *
 * The defect P8-b5 fixed was not cosmetic. With the start of a timed event
 * cleared, pressing save left the dialog open with NO message and an
 * unhandled rejection in the console -- `isoFromDatetimeLocalValue` threw on
 * the empty string, and `handleSave` called `buildSaveResult` outside its own
 * try. Measured in Chrome 155 before the fix, and again after.
 *
 * The controls cannot be rendered here (vitest runs with `environment:
 * 'node'`; jsdom is deliberately not added), so the conversion is tested
 * directly and the wiring is read from the source.
 */

import { describe, expect, it } from 'vitest';
import { isoFromDatetimeLocalValue, isoFromDateString, toDatetimeLocalValue } from '../../utils/datetime';

const SRC = import.meta.glob(
  ['/src/features/event/EventDialog.tsx', '/src/features/event/RecurrenceEditor.tsx', '/src/features/share/ShareDialog.tsx'],
  { query: '?raw', import: 'default', eager: true },
) as Record<string, string>;

const code = (t: string) =>
  t.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

const DLG = code(SRC['/src/features/event/EventDialog.tsx'] as string);
const REC = code(SRC['/src/features/event/RecurrenceEditor.tsx'] as string);
const SHARE = code(SRC['/src/features/share/ShareDialog.tsx'] as string);

describe('an empty value is not a date', () => {
  it('the conversion still throws rather than inventing one', () => {
    /*
      It must keep throwing. A function that quietly returned "now" for an
      empty string would put a wrong time on the event instead of refusing,
      and nothing downstream would know. The CALLER is what changed.
    */
    expect(() => isoFromDatetimeLocalValue('')).toThrow();
    expect(() => isoFromDatetimeLocalValue('not a date')).toThrow();
  });

  it('a partial string is not what the control hands over', () => {
    /*
      MEASURED: with the caret on the first segment, one Delete leaves
      input.value === '' and validity.badInput true. The control reports an
      EMPTY STRING for anything it cannot parse as a whole datetime -- it
      never hands over "2026-10-".

      Which is as well, because the Date constructor would accept that one:
      new Date('2026-10-') is the first of October, not an error. That
      leniency is unreachable from these inputs, and the empty check above is
      what actually stands between a cleared field and a saved event. This
      test records the reason the lenient case is not guarded.
    */
    expect(Number.isNaN(new Date('2026-10-').getTime())).toBe(false);
    expect(Number.isNaN(new Date('').getTime())).toBe(true);
  });

  it('a real value still converts, and the date form still works', () => {
    expect(() => isoFromDatetimeLocalValue('2026-10-18T09:00')).not.toThrow();
    // The instant is 09:00 LOCAL, so its UTC date depends on the OS zone
    // (2026-10-17 at +13). What has to hold everywhere: it is a UTC instant
    // that reads back as the value that was typed (P8-c1.1).
    expect(isoFromDatetimeLocalValue('2026-10-18T09:00')).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
    expect(toDatetimeLocalValue(isoFromDatetimeLocalValue('2026-10-18T09:00'))).toBe('2026-10-18T09:00');
    expect(() => isoFromDateString('2026-10-18')).not.toThrow();
  });
});

describe('the timed branch refuses an empty value before converting', () => {
  it('checks both fields, the way the all-day branch always did', () => {
    // The check has to come BEFORE the conversion, or the throw happens first
    // and the message is never set.
    const guard = DLG.indexOf('if (!startLocal || !endLocal) {');
    expect(guard, 'no empty check in the timed branch').toBeGreaterThan(-1);
    const convert = DLG.indexOf('isoFromDatetimeLocalValue(startLocal)');
    expect(convert).toBeGreaterThan(-1);
    expect(guard, 'the check runs after the conversion').toBeLessThan(convert);
  });

  it('reports it as a validation failure with a translated key', () => {
    const guard = DLG.indexOf('if (!startLocal || !endLocal) {');
    const after = DLG.slice(guard, guard + 220);
    expect(after).toContain("kind: 'validation'");
    expect(after).toContain("key: 'event.error.dateRequired'");
    expect(after).toContain('return null;');
  });

  it('the all-day branch keeps its own check', () => {
    expect(DLG).toContain('if (!startDate || !endDateInclusive) {');
  });
});

describe('nothing escapes the save handler', () => {
  it('buildSaveResult is called inside a try', () => {
    /*
      This is the backstop, not the fix. A value the checks above do not
      anticipate used to leave through handleSave as an unhandled rejection,
      which on screen is a save button that does nothing at all.
    */
    const i = DLG.indexOf('const handleSave = async');
    const body = DLG.slice(i, DLG.indexOf('\n  };', i));
    const tryAt = body.indexOf('try {');
    const callAt = body.indexOf('result = buildSaveResult()');
    expect(callAt, 'buildSaveResult is not called in handleSave').toBeGreaterThan(-1);
    expect(tryAt, 'buildSaveResult is called outside any try').toBeLessThan(callAt);
    // And the catch records the cause rather than swallowing it.
    expect(body.slice(callAt)).toContain("setFormError({ kind: 'caught', cause: e })");
  });
});

describe('an emptied or mistyped required date is marked at once, and refused at save', () => {
  /*
    WHAT P8-b5 GUARANTEED, RE-STATED FOR THE P8-b5.6b-2 INPUTS. P8-b5 put
    `required` on the four event date controls and the series end date so an
    emptied one matched :invalid and turned red the moment it happened (it
    measured that `required` did nothing else). Those native controls are gone:
    the owner adopted the typed date/time inputs, which do not use constraint
    validation. Their equivalent is: a draft that does not parse -- empty
    included -- turns the field red and says why on blur (DateTimeInputs), is
    reported through onInvalid, and readForm refuses to save while any shown
    field holds one. These two tests pin that wiring where the old two pinned
    the attribute. The share expiry test below is unchanged: it is still a
    native, optional control.
  */
  it('the dialog has no native date controls left, and all six inputs report their drafts', () => {
    expect(DLG.match(/<input\s+type="(date|datetime-local)"/g) ?? []).toEqual([]);
    expect(DLG.split('<DateInput').length - 1, 'two all-day dates + the timed start and end dates').toBe(3);
    expect(DLG.split('<TimeInput').length - 1, 'the timed start and end times').toBe(1);
    for (const field of ['allDayStart', 'allDayEnd']) {
      expect(DLG).toContain(`setDraftIssue('${field}', r)`);
    }
    expect(DLG).toContain("setDraftIssue(which === 'start' ? 'startDate' : 'endDate', r)");
    expect(DLG).toContain("setDraftIssue(which === 'start' ? 'startTime' : 'endTime', r)");
    // The timed pair is rendered for both start and end.
    expect(DLG).toContain("(['start', 'end'] as const).map((which)");
  });

  it('readForm refuses a draft before anything is converted, with the old sentence for an empty date', () => {
    const blocked = DLG.indexOf('const blocked = draftFields.find((k) => draftIssues[k]);');
    expect(blocked, 'no draft check in readForm').toBeGreaterThan(-1);
    expect(blocked).toBeLessThan(DLG.indexOf('isoFromDateString(startDate)'));
    expect(blocked).toBeLessThan(DLG.indexOf('isoFromDatetimeLocalValue(startLocal)'));
    expect(DLG).toContain("empty: draftIssues[blocked] === 'empty'");
  });

  it('the recurrence end date reports its draft too, since it only renders when needed', () => {
    expect(REC.match(/<input\s+type="date"/g) ?? []).toEqual([]);
    expect(REC.split('<DateInput').length - 1).toBe(1);
    expect(REC).toContain('onInvalid={(reason) => onUntilInvalid?.(reason)}');
    expect(DLG).toContain("onUntilInvalid={(r) => setDraftIssue('until', r)}");
    // ...and counts only while the until field is shown and editable.
    expect(DLG).toContain("recurrenceForm.endMode === 'until'");
  });

  it('the share link expiry does NOT, because it is optional', () => {
    /*
      An optional field that cannot be cleared is a worse bug than the one
      this task set out to fix: there would be no way to remove an expiry
      once set.
    */
    const inputs = SHARE.match(/<input\s+type="datetime-local"[\s\S]*?\/>/g) ?? [];
    expect(inputs.length).toBe(1);
    expect(inputs[0]).not.toContain('required');
  });
});
