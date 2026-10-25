import { describe, expect, it } from 'vitest';
import {
  needsFetch,
  retainStored,
  shouldApplyFetchResult,
  shouldLoadStoredLanguage,
} from './languageState';
import { resolveLanguage } from './resolveLanguage';

const OWNER = 'owner-a';
const OTHER = 'owner-b';

describe('shouldLoadStoredLanguage', () => {
  it('loads for a signed-in owner on the app route', () => {
    expect(shouldLoadStoredLanguage({ isPublicRoute: false, authEnabled: true, userId: OWNER }))
      .toBe(true);
  });

  it('NEVER loads on the anonymous share route', () => {
    // anon holds no privilege on owner_settings (0025/0026), so the request
    // could only earn a 42501 -- and it is the wrong question anyway: an
    // anonymous viewer must get their own browser language, not the owner's.
    expect(shouldLoadStoredLanguage({ isPublicRoute: true, authEnabled: true, userId: OWNER }))
      .toBe(false);
    expect(shouldLoadStoredLanguage({ isPublicRoute: true, authEnabled: true, userId: null }))
      .toBe(false);
  });

  it('does not load when signed out', () => {
    expect(shouldLoadStoredLanguage({ isPublicRoute: false, authEnabled: true, userId: null }))
      .toBe(false);
  });

  it('does not load in local mode, which has no owner row', () => {
    expect(shouldLoadStoredLanguage({ isPublicRoute: false, authEnabled: false, userId: OWNER }))
      .toBe(false);
  });
});

describe('needsFetch: one query per user', () => {
  it('fetches when nothing has been loaded yet', () => {
    expect(needsFetch({ shouldLoad: true, userId: OWNER, loadedFor: null })).toBe(true);
  });

  it('does NOT re-fetch once loaded for the same user', () => {
    // The effect re-runs on every auth event Supabase emits, token refreshes
    // included. Each of those must not cost a round trip.
    expect(needsFetch({ shouldLoad: true, userId: OWNER, loadedFor: OWNER })).toBe(false);
  });

  it('fetches again when the user changes', () => {
    expect(needsFetch({ shouldLoad: true, userId: OTHER, loadedFor: OWNER })).toBe(true);
  });

  it('never fetches when loading is not allowed', () => {
    expect(needsFetch({ shouldLoad: false, userId: OWNER, loadedFor: null })).toBe(false);
  });
});

/**
 * The leak guard. A stored preference belongs to one account, and must not
 * survive the account leaving.
 */
describe('retainStored', () => {
  it('keeps the value for the user it was loaded for', () => {
    expect(retainStored({ stored: 'en', loadedFor: OWNER, userId: OWNER })).toBe('en');
  });

  it('DROPS it on sign-out', () => {
    // Otherwise the next person on this tab -- or an anonymous visitor -- sees
    // the previous owner's language.
    expect(retainStored({ stored: 'en', loadedFor: OWNER, userId: null })).toBeNull();
  });

  it('DROPS it the instant the user changes, before any refetch lands', () => {
    // The guard is applied at read time rather than in an effect, so there is
    // no render in which B is shown A's preference.
    expect(retainStored({ stored: 'en', loadedFor: OWNER, userId: OTHER })).toBeNull();
  });

  it('dropping falls back to the browser, not to a blank UI', () => {
    const dropped = retainStored({ stored: 'en', loadedFor: OWNER, userId: null });
    expect(resolveLanguage({ stored: dropped, browser: ['ja-JP'] })).toBe('ja');
    expect(resolveLanguage({ stored: dropped, browser: ['en-US'] })).toBe('en');
  });
});

/**
 * The whole resolution, walked as a sequence of states, since that is what the
 * provider actually does over a session.
 */
describe('end to end: the states a session passes through', () => {
  const browserJa = ['ja-JP'];
  const browserEn = ['en-US'];

  const resolveFor = (s: {
    isPublicRoute?: boolean; authEnabled?: boolean; userId: string | null;
    stored: 'ja' | 'en' | null; loadedFor: string | null; browser: readonly string[];
  }) => resolveLanguage({
    stored: retainStored({ stored: s.stored, loadedFor: s.loadedFor, userId: s.userId }),
    browser: s.browser,
  });

  it('stored en beats a Japanese browser', () => {
    expect(resolveFor({ userId: OWNER, stored: 'en', loadedFor: OWNER, browser: browserJa }))
      .toBe('en');
  });

  it('stored ja beats an English browser', () => {
    expect(resolveFor({ userId: OWNER, stored: 'ja', loadedFor: OWNER, browser: browserEn }))
      .toBe('ja');
  });

  it('unset follows the browser', () => {
    expect(resolveFor({ userId: OWNER, stored: null, loadedFor: OWNER, browser: browserEn }))
      .toBe('en');
    expect(resolveFor({ userId: OWNER, stored: null, loadedFor: OWNER, browser: ['fr-FR'] }))
      .toBe('ja');
  });

  it('before the fetch resolves, the browser answers', () => {
    // No flash of the wrong language and no blank: the pre-fetch state is the
    // same as "owner has set nothing", which is a legitimate steady state.
    expect(resolveFor({ userId: OWNER, stored: null, loadedFor: null, browser: browserEn }))
      .toBe('en');
  });

  it('a failed fetch behaves exactly like "nothing stored"', () => {
    // The provider sets stored=null on error and marks the user loaded, so the
    // page renders in the browser language instead of breaking or retrying.
    expect(resolveFor({ userId: OWNER, stored: null, loadedFor: OWNER, browser: browserEn }))
      .toBe('en');
  });

  it('signing out of an English account on a Japanese browser gives Japanese', () => {
    expect(resolveFor({ userId: null, stored: 'en', loadedFor: OWNER, browser: browserJa }))
      .toBe('ja');
  });

  it('switching accounts does not carry the language across', () => {
    expect(resolveFor({ userId: OTHER, stored: 'en', loadedFor: OWNER, browser: browserJa }))
      .toBe('ja');
  });

  it('the anonymous share route uses the VIEWER browser, never a stored value', () => {
    // isPublicRoute short-circuits the fetch, so `stored` is structurally null.
    expect(shouldLoadStoredLanguage({ isPublicRoute: true, authEnabled: true, userId: OWNER }))
      .toBe(false);
    expect(resolveFor({ isPublicRoute: true, userId: null, stored: null, loadedFor: null, browser: browserEn }))
      .toBe('en');
  });

  it('saving a new preference changes the answer with no refetch', () => {
    // setStoredLanguage sets both stored and loadedFor, so the next render
    // resolves to the new value.
    const before = resolveFor({ userId: OWNER, stored: null, loadedFor: OWNER, browser: browserJa });
    const after = resolveFor({ userId: OWNER, stored: 'en', loadedFor: OWNER, browser: browserJa });
    expect(before).toBe('ja');
    expect(after).toBe('en');
  });
});

/**
 * The save-versus-fetch race.
 *
 * The provider issues one settings request when a user signs in. If the owner
 * saves a language before it returns, the response carries the pre-save value
 * and would silently undo the save -- the owner picks English, the page keeps
 * resolving Japanese, and nothing explains why.
 *
 * The provider currently survives this by accident (loadedFor sits in the
 * effect deps, a save changes it, React cancels the old effect). These pin the
 * rule directly so removing that dep cannot reopen the race unnoticed.
 */
describe('shouldApplyFetchResult', () => {
  const base = {
    cancelled: false,
    requestedFor: OWNER,
    currentUserId: OWNER,
    writeSeqAtRequest: 0,
    writeSeqNow: 0,
  };

  it('applies a response that nothing overtook', () => {
    expect(shouldApplyFetchResult(base)).toBe(true);
  });

  it('REFUSES a response when a save landed while it was in flight', () => {
    expect(shouldApplyFetchResult({ ...base, writeSeqNow: 1 })).toBe(false);
  });

  it('refuses after several saves', () => {
    expect(shouldApplyFetchResult({ ...base, writeSeqAtRequest: 2, writeSeqNow: 5 })).toBe(false);
  });

  it('applies when saves happened BEFORE the request was issued', () => {
    // The counter is compared, not merely checked for zero: a request issued
    // after two saves is still current if no third save has happened.
    expect(shouldApplyFetchResult({ ...base, writeSeqAtRequest: 2, writeSeqNow: 2 })).toBe(true);
  });

  it('refuses a cancelled request', () => {
    expect(shouldApplyFetchResult({ ...base, cancelled: true })).toBe(false);
  });

  it('refuses a response for a user who is no longer current', () => {
    expect(shouldApplyFetchResult({ ...base, currentUserId: OTHER })).toBe(false);
    expect(shouldApplyFetchResult({ ...base, currentUserId: null })).toBe(false);
  });

  it('the saved value survives the whole sequence', () => {
    // sign in -> request issued -> owner saves 'en' -> stale response arrives
    const seqAtRequest = 0;
    let stored: 'ja' | 'en' | null = null;
    let seq = seqAtRequest;

    // the save
    seq += 1;
    stored = 'en';

    // the stale response, carrying the pre-save value
    const apply = shouldApplyFetchResult({
      cancelled: false, requestedFor: OWNER, currentUserId: OWNER,
      writeSeqAtRequest: seqAtRequest, writeSeqNow: seq,
    });
    if (apply) stored = null;

    expect(apply).toBe(false);
    expect(stored).toBe('en');
    expect(resolveLanguage({ stored, browser: ['ja-JP'] })).toBe('en');
  });
});
