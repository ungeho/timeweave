/**
 * What the share dialog must not do twice, and what it must not quietly
 * change.
 *
 * The dialog cannot be rendered here -- vitest runs with `environment: 'node'`
 * and jsdom is deliberately not added -- so these read its source. That is
 * enough for the two properties at stake: whether a guard EXISTS on each
 * mutating handler, and whether the privacy defaults are still written the
 * way the share model requires. Both were verified in a browser as well; the
 * source test is what keeps them from being removed later.
 */

import { describe, expect, it } from 'vitest';

const SHARE = (
  import.meta.glob('/src/features/share/ShareDialog.tsx', {
    query: '?raw',
    import: 'default',
    eager: true,
  }) as Record<string, string>
)['/src/features/share/ShareDialog.tsx'] as string;

const code = (t: string) =>
  t.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

const C = code(SHARE);

/** The body of a named handler, up to its closing brace at that indent. */
function handler(name: string): string {
  const i = C.indexOf(`const ${name} = async`);
  expect(i, name).toBeGreaterThan(-1);
  const end = C.indexOf('\n  };', i);
  return C.slice(i, end);
}

describe('every mutating handler has a re-entry guard', () => {
  /*
    MEASURED, NOT ASSUMED. With the create guard removed and the button
    tapped three times, the mock backend received three create calls and the
    list grew by three -- three live links, each with a token shown only
    once, so two of them existed with no way to reach their URL. With the
    guard, the same three taps create one.

    A ref, not state: both presses in one tick read the render that had not
    disabled anything yet. deletingRef and togglingRef were already written
    this way; create and revoke were not, and this is what that cost.
  */
  it.each([
    ['handleCreate', 'creatingRef'],
    ['handleRevoke', 'revokingRef'],
    ['handleDelete', 'deletingRef'],
    ['handleToggleAvailable', 'togglingRef'],
  ])('%s returns early when %s is set', (name, ref) => {
    /*
      An EARLY RETURN, not a mention. A first version of this asked only
      whether the handler named the ref, which the line that SETS it already
      satisfies -- deleting the guard left the test green. What has to be
      there is a branch that reads the ref and leaves before the request.
    */
    const body = handler(name);
    const guard = new RegExp(`if \\([^)]*${ref}\\.current[^)]*\\) return;`);
    expect(body, `${name} has no early return on ${ref}`).toMatch(guard);
    const at = body.search(guard);
    expect(at, `${name} guards after awaiting`).toBeLessThan(body.indexOf('await '));
    // And before the flag is set, or the second caller sets it first.
    expect(at, name).toBeLessThan(body.indexOf(`${ref}.current = `));
  });

  it.each([
    ['handleCreate', 'creatingRef'],
    ['handleRevoke', 'revokingRef'],
    ['handleDelete', 'deletingRef'],
    ['handleToggleAvailable', 'togglingRef'],
  ])('%s releases %s in a finally', (name, ref) => {
    const body = handler(name);
    const fin = body.indexOf('} finally {');
    expect(fin, `${name} has no finally`).toBeGreaterThan(-1);
    // Released on the failure path too: a throw that left the flag set would
    // lock the control for the rest of the dialog's life.
    expect(body.slice(fin), name).toContain(`${ref}.current = `);
  });

  it('does not close while a request is in flight', () => {
    const i = C.indexOf('useDialogChrome(');
    expect(i).toBeGreaterThan(-1);
    const call = C.slice(i, i + 300);
    for (const ref of ['creatingRef', 'deletingRef', 'togglingRef', 'revokingRef']) {
      expect(call, ref).toContain(ref);
    }
  });
});

describe('the disclosure settings keep their meaning', () => {
  it('include_private still defaults to true', () => {
    /*
      NOT A TIDY-UP TARGET. The default is part of what a share link means in
      this app -- a link shows private events as busy unless the owner says
      otherwise -- and flipping it while rearranging the layout would change
      what every link created afterwards discloses, with nothing on screen
      saying so.
    */
    expect(C).toMatch(/const \[includePrivate, setIncludePrivate\] = useState\(true\)/);
  });

  it('share_available is still opt-in', () => {
    // 0022: the owner asks for it. A default of true would publish free time
    // from every link made from then on.
    expect(C).toMatch(/const \[shareAvailableNew, setShareAvailableNew\] = useState\(false\)/);
  });

  it('the two are passed independently to create', () => {
    // They answer different questions -- which events are counted, and
    // whether free time is published -- and neither implies the other.
    const body = handler('handleCreate');
    expect(body).toContain('includePrivate,');
    expect(body).toContain('shareAvailable: shareAvailableNew,');
  });

  it('available is set at creation, not toggled afterwards', () => {
    // A create-then-toggle would leave a window where the token is live and
    // the setting is still the default.
    const body = handler('handleCreate');
    expect(body).not.toContain('setShareAvailable(');
  });

  it('keeps both settings between creations rather than resetting', () => {
    const body = handler('handleCreate');
    // The label and expiry clear; the disclosure choices do not.
    expect(body).toContain("setLabel('')");
    expect(body).toContain("setExpiresLocal('')");
    expect(body).not.toContain('setIncludePrivate(');
    expect(body).not.toContain('setShareAvailableNew(');
  });

  it('offers the available switch only on rows the RPC would accept', () => {
    // An expired or revoked link shows its setting but no switch: 0022
    // refuses those, and a switch that always failed would be worse than none.
    expect(C).toContain('canSetShareAvailable(l, now)');
  });
});

describe('the phone reaches everything the desktop does', () => {
  it('renders one body for both shells', () => {
    expect(C).toContain('const body = (');
    expect(C.split('{body}').length - 1).toBe(2);
  });

  it.each([
    'shareDialog.create',
    'shareDialog.revoke',
    'shareDialog.delete',
    'shareDialog.confirmDelete',
    'shareDialog.created.copy',
    'shareDialog.list.revokedOnly',
    'shareDialog.label',
  ])('%s is written once, so neither shell can lose it', (key) => {
    expect(C.split(`'${key}'`).length - 1).toBe(1);
  });
});
