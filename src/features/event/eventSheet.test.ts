/**
 * What the mobile event sheet guarantees.
 *
 * The sheet cannot be rendered here -- vitest runs with `environment: 'node'`
 * and jsdom is deliberately not added -- so these read the source and the
 * stylesheet for the properties that only exist in markup and CSS. The
 * behaviour they stand in for was measured in a browser; see
 * docs/p8-tasks.md for what that covered and what it could not.
 */

import { describe, expect, it } from 'vitest';
import { readStylesheet } from '../../../scripts/read-stylesheet.mjs';

const DIALOG = (
  import.meta.glob('/src/features/event/EventDialog.tsx', {
    query: '?raw',
    import: 'default',
    eager: true,
  }) as Record<string, string>
)['/src/features/event/EventDialog.tsx'] as string;

const CSS = readStylesheet();

/** Source with comments removed, so a rule never matches its own rationale. */
const code = (t: string) =>
  t.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

const DIALOG_CODE = code(DIALOG);

describe('one field tree, two shells', () => {
  it('renders the fields once, not once per shell', () => {
    /*
      THE WHOLE POINT. A second copy of the field tree is a second place for a
      validation, an option list or a label to be forgotten, and the two
      would drift apart silently -- the desktop path is the one nobody
      re-checks on a phone. Each field appears exactly once in the source and
      both shells render the same `fields` variable.
    */
    for (const key of [
      'event.field.title',
      'event.field.start',
      'event.field.end',
      'event.field.description',
      'event.field.category',
      'event.field.visibility',
      'event.field.availability',
      'event.field.startDate',
      'event.field.endDate',
      'event.field.allDay',
      'event.scope.label',
    ]) {
      const n = DIALOG_CODE.split(`'${key}'`).length - 1;
      expect(n, `${key} appears ${n} times`).toBe(1);
    }
  });

  it('both shells render the same fields variable', () => {
    expect(DIALOG_CODE).toContain('const fields = (');
    expect(DIALOG_CODE.split('{fields}').length - 1).toBe(2);
  });

  it('the recurrence editor is rendered once, for both shells', () => {
    expect(DIALOG_CODE.split('<RecurrenceEditor').length - 1).toBe(1);
  });

  it('the sheet keeps every control the modal has', () => {
    // Delete is the one that could plausibly be dropped on a phone for room.
    expect(DIALOG_CODE).toContain('const deleteButton =');
    expect(DIALOG_CODE.split('{deleteButton}').length - 1).toBe(2);
    expect(DIALOG_CODE).toContain("tr('common.delete')");
  });
});

describe('saving is in flight or it is not', () => {
  it('guards on a ref, not only on state', () => {
    /*
      State does not update in time to stop a second call in the same tick, so
      a double tap on a 44px save button would create two events. The ref is
      what actually guards.
    */
    expect(DIALOG_CODE).toContain('busyRef.current');
    expect(DIALOG_CODE).toMatch(/if \(busyRef\.current\) return;/);
    expect(DIALOG_CODE).toMatch(/if \(!occ \|\| busyRef\.current\) return;/);
  });

  it('every button that acts or closes is disabled while busy', () => {
    const buttons = DIALOG_CODE.match(/<button[^>]*>/gs) ?? [];
    const acting = buttons.filter((b) => /onClick=\{(handleSave|handleDelete|onClose)\}/.test(b));
    expect(acting.length).toBeGreaterThanOrEqual(5);
    for (const b of acting) {
      expect(b, b.slice(0, 60)).toContain('disabled={busy}');
    }
  });

  it('says so on the button rather than looking idle', () => {
    expect(DIALOG_CODE.split("tr('common.saving')").length - 1).toBe(2);
  });

  it('clears the flag only on failure, never after closing', () => {
    // On success the dialog unmounts; clearing there would set state on it.
    const save = DIALOG_CODE.slice(DIALOG_CODE.indexOf('const handleSave'));
    const body = save.slice(0, save.indexOf('};'));
    expect(body.indexOf('setBusy(false)')).toBeGreaterThan(body.indexOf('catch'));
  });
});

describe('escape and the background', () => {
  /*
    P8-b4 moved this into useDialogChrome, because the share and settings
    dialogs owe their readers the same two things and a third copy is where
    the three would drift. The assertions follow it rather than being
    dropped, and gain the one that only matters once it is shared: that every
    dialog actually calls it.
  */
  const CHROME = code(
    (
      import.meta.glob('/src/hooks/useDialogChrome.ts', {
        query: '?raw',
        import: 'default',
        eager: true,
      }) as Record<string, string>
    )['/src/hooks/useDialogChrome.ts'] as string,
  );

  const DIALOGS = import.meta.glob(
    [
      '/src/features/event/EventDialog.tsx',
      '/src/features/share/ShareDialog.tsx',
      '/src/features/settings/SettingsDialog.tsx',
    ],
    { query: '?raw', import: 'default', eager: true },
  ) as Record<string, string>;

  it('closes on Escape and restores what it locked', () => {
    expect(CHROME).toContain("e.key === 'Escape'");
    expect(CHROME).toContain("document.body.style.overflow = 'hidden'");
    // Restores the PREVIOUS value, not a guessed one: with two dialogs open,
    // clearing would unlock the page under the one still showing.
    expect(CHROME).toContain('const previous = document.body.style.overflow');
    expect(CHROME).toContain('document.body.style.overflow = previous');
  });

  it('every dialog uses it, and none keeps its own copy', () => {
    for (const [path, text] of Object.entries(DIALOGS)) {
      const c = code(text);
      expect(c, path).toContain('useDialogChrome(');
      // A dialog that still set the lock itself would be a second owner of
      // the same global, and the two restores would fight.
      expect(c, path).not.toContain('document.body.style.overflow');
    }
  });

  it('does not close while a request is in flight', () => {
    expect(CHROME).toContain('!blocked?.()');
    // Each dialog passes what "in flight" means for it, read through a ref so
    // the answer is current rather than the one from the last render.
    for (const [path, text] of Object.entries(DIALOGS)) {
      const i = code(text).indexOf('useDialogChrome(');
      expect(i, path).toBeGreaterThan(-1);
      expect(code(text).slice(i, i + 400), path).toContain('Ref.current');
    }
  });
});

describe('the sheet stylesheet', () => {
  /*
    Exactly the sheet rules: from the banner to the end marker. Slicing to
    the end of the file was enough until P8-b4 added a block BELOW them that
    styles the desktop modal at narrow widths -- which is allowed, and which
    the old slice read as a violation.
  */
  const START = CSS.indexOf('.sheet-backdrop');
  const END = CSS.indexOf('---------- end of sheet rules');
  const sheet = CSS.slice(START, END);

  it('sizes itself in dvh, never vh', () => {
    /*
      `100vh` on a phone is the viewport with the browser chrome retracted --
      a height the page does not have while the address bar shows -- so the
      header scrolls off. `dvh` tracks the viewport as it is, and shrinks when
      Android Chrome makes room for the keyboard.
    */
    expect(sheet).toContain('height: 100dvh');
    expect(sheet).not.toMatch(/height:\s*100vh/);
  });

  it('scrolls the body, not the sheet', () => {
    // If the sheet scrolled, the header would scroll away with it and save
    // would be unreachable behind a keyboard.
    expect(sheet).toMatch(/\.sheet-body\s*\{[^}]*overflow-y:\s*auto/);
    expect(sheet).toMatch(/\.sheet-body\s*\{[^}]*min-height:\s*0/);
    expect(sheet).toMatch(/\.sheet-header[^{]*\{[^}]*position:\s*sticky/);
  });

  it('gives every typed control a 44px target, not just direct children', () => {
    /*
      A first version scoped this to `.field > input` and left nine controls
      inside the recurrence fieldset at 34px, because those nest one level
      deeper. Matching on the control rather than its position is what fixed
      it.
    */
    expect(sheet).toContain(".sheet-body input:not([type='checkbox']):not([type='radio'])");
    expect(sheet).not.toMatch(/\.sheet-body \.field > input,/);
    // A checkbox is a fixed glyph: its label carries the target.
    expect(sheet).toContain(".sheet-body label:has(> input[type='checkbox'])");
    expect(sheet).toContain('.sheet-body .weekday-chip');
  });

  it('cannot widen past the viewport', () => {
    expect(sheet).toMatch(/\.sheet-body\s*\{[^}]*min-width:\s*0/);
    expect(sheet).toMatch(/overflow-wrap:\s*anywhere/);
    // The two-up rows stack rather than squeezing a pair of dates into 320px.
    expect(sheet).toMatch(/\.sheet-body \.field-row\s*\{[^}]*flex-direction:\s*column/);
  });

  it('has both markers, so the slice is the real section', () => {
    expect(START).toBeGreaterThan(-1);
    expect(END).toBeGreaterThan(START);
    // A slice that collapsed to nothing would pass every rule below it.
    expect(sheet.length).toBeGreaterThan(1000);
    expect(sheet).toContain('.sheet-body');
  });

  it('keeps the desktop dialog out of reach', () => {
    // Every sheet rule is scoped to .sheet*; none may name .modal, or the
    // desktop dialog would change with the phone.
    const rules = sheet.replace(/\/\*[\s\S]*?\*\//g, '');
    expect(rules).not.toContain('.modal');
  });
});
