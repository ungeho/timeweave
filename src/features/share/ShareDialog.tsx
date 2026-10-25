/**
 * Manage Free/Busy share links: create (with include-private + optional expiry),
 * list, revoke, and delete. The plaintext token is shown ONCE right after
 * creation and cannot be retrieved later (only its hash is stored), which the UI
 * states explicitly.
 *
 * REVOKE AND DELETE ARE TWO DIFFERENT VERBS, and the dialog never lets them be
 * confused. Revoking stops a URL working and leaves the row, which still counts
 * against the total quota (0016). Deleting removes the row and frees that slot,
 * and migration 0015 will only do it to an ALREADY-REVOKED row -- so the delete
 * button appears on exactly those rows, and an expired-but-not-revoked link says
 * so rather than offering a button the RPC would silently refuse. The rule
 * itself lives in shareLinkState.ts, where it can be tested; this file renders
 * it, because the project has no component-test environment. The management
 * label's length rule lives in shareLinkLabel.ts for the same reason.
 */

import { useEffect, useRef, useState } from 'react';
import { useIsMobile } from '../../hooks/useIsMobile';
import { useDialogChrome } from '../../hooks/useDialogChrome';
import {
  createShareLink,
  deleteShareLink,
  listShareLinks,
  revokeShareLink,
  setShareAvailable,
} from '../../repositories/shareRepository';
import type { CreatedShareLink, ShareLink } from '../../types/share';
import { getUserTimeZone } from '../../utils/timezone';
import { WallTimeNotice } from '../event/WallTimeNotice';
import { shareExpiryFold, shareExpiryFromLocal, type ShareExpiryPick } from './shareExpiry';
import { shareExpiryLabel } from './shareExpiryLabel';
import { useLanguage, useTranslate } from '../../i18n/useLanguage';
import { intlLocale } from '../../i18n/resolveLanguage';
import { SHARE_LABEL_MAX, labelLengthError, shareLabelLength } from './shareLinkLabel';
import {
  shareDialogErrorText,
  type ShareDialogError,
  type ShareDialogNotice,
} from './shareError';
import {
  canDeleteShareLink,
  canSetShareAvailable,
  shareLinkStatus,
  visibleShareLinks,
} from './shareLinkState';

const shareUrl = (token: string) => `${window.location.origin}/s/${token}`;

const STATUS_KEY = {
  active: 'shareDialog.status.active',
  expired: 'shareDialog.status.expired',
  revoked: 'shareDialog.status.revoked',
} as const;

export function ShareDialog({ onClose }: { onClose: () => void }) {
  const tr = useTranslate();
  // Only for the expiry LINE. The expiry DECISION is shareLinkStatus’s, from
  // the stored instant against `now` -- no locale reaches it.
  const { language } = useLanguage();
  const [links, setLinks] = useState<ShareLink[]>([]);
  const [loading, setLoading] = useState(true);
  // NEITHER OF THESE HOLDS A SENTENCE. Both used to: `error` was filled from
  // `e.message` or from `labelLengthError`, and `notice` from `tr(...)`, so
  // both froze their wording at the moment they were set. A language change
  // afterwards re-rendered every other string in this dialog and left these
  // two in the old language. The error now keeps the cause (or the fact), the
  // notice keeps its key, and both are read in `language` at render.
  const [error, setError] = useState<ShareDialogError | null>(null);
  const [notice, setNotice] = useState<ShareDialogNotice | null>(null);

  const [label, setLabel] = useState('');
  const [includePrivate, setIncludePrivate] = useState(true);
  // Defaults to OFF, unlike includePrivate. Sharing busy time is what a share
  // link is for, so including private events in it is the expected shape; open
  // time is a second, additive disclosure the owner has to choose.
  const [shareAvailableNew, setShareAvailableNew] = useState(false);
  const [expiresLocal, setExpiresLocal] = useState('');
  // Which of two identical wall clocks the owner picked (E1, P8-c3.1). Bound to
  // the value and the zone it was picked for; any change asks again.
  const [expiryPick, setExpiryPick] = useState<ShareExpiryPick | null>(null);
  // Past / unchosen are explained once Create has been pressed, then kept up to
  // date as the field changes. A missing time is explained at once (P8-c3).
  const [expiryAttempted, setExpiryAttempted] = useState(false);
  const expiryInputRef = useRef<HTMLInputElement>(null);
  // The browser's zone (E2), read on every render rather than once, so a device
  // that changes zone while the dialog is open is judged in the zone it is in
  // now; handleCreate reads it again for the same reason.
  const timeZone = getUserTimeZone();
  const expiry = shareExpiryFromLocal(expiresLocal, timeZone, expiryPick);
  const expiryFoldCheck = shareExpiryFold(expiry);
  const expiryMessage =
    expiryAttempted && expiry.kind === 'past'
      ? tr('shareDialog.expiry.past')
      : expiryAttempted && expiry.kind === 'foldUnchosen'
        ? tr('shareDialog.expiry.foldUnchosen')
        : null;
  const expiryDescribedBy =
    [expiry.kind === 'gap' || expiryFoldCheck ? 'share-expiry-dst' : null, expiryMessage ? 'share-expiry-error' : null]
      .filter(Boolean)
      .join(' ') || undefined;
  const [creating, setCreating] = useState(false);
  const [justCreated, setJustCreated] = useState<CreatedShareLink | null>(null);
  const [copied, setCopied] = useState(false);

  const [revokedOnly, setRevokedOnly] = useState(false);
  const [confirmingDeleteId, setConfirmingDeleteId] = useState<string | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [togglingId, setTogglingId] = useState<string | null>(null);
  const [revokingId, setRevokingId] = useState<string | null>(null);
  const isMobile = useIsMobile();
  // Escape is blocked while a link is being created, deleted, toggled or
  // revoked: those report their outcome into this dialog, and closing would
  // throw away the only place the result appears.
  useDialogChrome(
    onClose,
    () =>
      creatingRef.current || deletingRef.current !== null ||
      togglingRef.current !== null || revokingRef.current !== null,
  );

  // A delete OR an available-toggle in flight disables every other mutating
  // control, so a second request can never be issued against a list that is
  // about to be replaced.
  const busy = deletingId !== null || togglingId !== null;
  const deletingRef = useRef<string | null>(null);
  // Same door as deletingRef, and needed for the same reason: two clicks
  // delivered in one tick both see the render that disabled nothing yet. Here
  // the cost is worse than a misleading message -- the two calls would carry
  // opposite values, and whichever the server applied last would win, leaving
  // the switch showing a setting the owner did not choose.
  const togglingRef = useRef<string | null>(null);
  /*
    THE SAME DOOR, ON THE TWO HANDLERS THAT DID NOT HAVE ONE.

    deletingRef and togglingRef above already say why state is not enough: two
    presses delivered in one tick both see the render that disabled nothing
    yet. Create and revoke were written without that guard --
    `disabled={creating || busy}` is state, and revoke set neither flag -- so
    the same double tap creates TWO share links, each with its own token that
    the owner only sees once, or sends two revokes for one link.

    Creating two is the one that matters: a token handed out in the banner is
    the only time it is visible, so the second link exists, is live, and its
    token is never shown. Nothing in the dialog would reveal it had happened.
  */
  const creatingRef = useRef(false);
  const revokingRef = useRef<string | null>(null);

  /**
   * Any reload invalidates a pending confirmation: the row it referred to may
   * not be in the new list, and a confirm that outlived its row would arm the
   * wrong one. Clearing it here means no caller has to remember to.
   */
  const refresh = async () => {
    setLoading(true);
    setError(null);
    setNotice(null);
    setConfirmingDeleteId(null);
    try {
      setLinks(await listShareLinks());
    } catch (e) {
      setError({ kind: 'caught', cause: e });
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void refresh();
  }, []);

  const handleCreate = async () => {
    if (creatingRef.current) return;
    setError(null);
    setNotice(null);
    setConfirmingDeleteId(null);
    setCopied(false);
    // The expiry is judged AGAIN here, with the zone and the clock of this
    // moment -- not the render's. Nothing is sent for a time that does not
    // exist (P8-c3), an unchosen fold (E1) or a time that is not in the future
    // (E3). The last is a courtesy: the database CHECK expires_at > created_at,
    // on the server's clock, stays the boundary.
    const expiryNow = shareExpiryFromLocal(expiresLocal, getUserTimeZone(), expiryPick, Date.now());
    if (expiryNow.kind !== 'none' && expiryNow.kind !== 'instant') {
      setExpiryAttempted(true);
      expiryInputRef.current?.focus();
      return;
    }
    // Normally unreachable through this input, which enforces the same product
    // limit with maxLength. The rule is stated once more at the submit boundary
    // for programmatic values and future input paths. The database's 200-byte
    // CHECK is a separate storage bound -- 50 UTF-16 units occupy at most 150
    // UTF-8 bytes, so it cannot fire for anything this guard accepts.
    // The RULE is still shareLinkLabel's, and still asked the same way. What
    // is stored is the FACT plus the number the sentence quotes -- not the
    // sentence -- so the refusal follows the language like everything else.
    // `max` rather than a re-measurement at render: the owner is still editing
    // this field, and re-deriving would make the message vanish mid-keystroke,
    // which is not when this dialog has ever cleared it.
    if (labelLengthError(label) !== null) {
      setError({ kind: 'labelTooLong', max: SHARE_LABEL_MAX });
      return;
    }
    creatingRef.current = true;
    setCreating(true);
    try {
      // Set AT CREATION, in the same RPC call, rather than created and then
      // toggled. create_share_link takes p_share_available (0022), so the link
      // never exists in a state the owner did not ask for -- a follow-up
      // set_share_available would leave a window in which the token is already
      // valid and the setting is still the default, and would need its own
      // failure story for a link that had already been handed back.
      const created = await createShareLink({
        label: label.trim() || null,
        includePrivate,
        expiresAt: expiryNow.kind === 'instant' ? expiryNow.iso : null,
        shareAvailable: shareAvailableNew,
      });
      setJustCreated(created);
      setLabel('');
      setExpiresLocal('');
      setExpiryPick(null);
      setExpiryAttempted(false);
      // includePrivate and shareAvailable deliberately KEEP their values: an
      // owner creating several links usually wants the same disclosure settings
      // for them, and resetting would quietly turn the choice off between two
      // creations.
      await refresh();
    } catch (e) {
      setError({ kind: 'caught', cause: e });
    } finally {
      creatingRef.current = false;
      setCreating(false);
    }
  };

  const handleRevoke = async (id: string) => {
    /*
      Re-entry only, and only for this row. Revoke deliberately does NOT join
      `busy`: that flag exists so a delete or a toggle cannot race a list
      that is about to be replaced, and widening it here would disable
      controls that were live before, which is a behaviour change this task
      has no reason to make. Blocking a second revoke OF THE SAME LINK is
      enough to stop the duplicate call.
    */
    if (revokingRef.current === id) return;
    revokingRef.current = id;
    setRevokingId(id);
    setError(null);
    setNotice(null);
    setConfirmingDeleteId(null);
    try {
      await revokeShareLink(id);
      if (justCreated?.id === id) setJustCreated(null);
      await refresh();
    } catch (e) {
      setError({ kind: 'caught', cause: e });
    } finally {
      revokingRef.current = null;
      setRevokingId(null);
    }
  };

  /**
   * The row is never removed optimistically: it disappears because the refreshed
   * list no longer contains it. A refusal (false) is reported and the list is
   * still refreshed, since the most likely cause is that the row is already
   * gone. A thrown error leaves the list exactly as it was, so the link the
   * owner was acting on is still in front of them, and nothing is retried.
   */
  const handleDelete = async (id: string) => {
    // The ref, not `busy`, is what actually closes the door. Two clicks
    // delivered in one tick both run against the render that disabled nothing
    // yet, so both would see busy === false and both would call the RPC. The
    // second call is harmless at the database (0015 is idempotent) but it comes
    // back false, and the owner would be told their link "was already deleted"
    // about a delete they did not make twice.
    if (deletingRef.current !== null) return;
    deletingRef.current = id;
    setError(null);
    setNotice(null);
    setDeletingId(id);
    try {
      const deleted = await deleteShareLink(id);
      await refresh();
      // 0015 returns false for a row that is absent, someone else's, or still
      // active, without distinguishing them. The delete button only appears on
      // the owner's revoked rows, so in practice this means the row is already
      // gone -- another tab, most likely. It is not a failure, so it goes to
      // `notice` rather than `error`.
      if (!deleted) setNotice('shareDialog.deleteRefused');
    } catch (e) {
      setError({ kind: 'caught', cause: e });
    } finally {
      deletingRef.current = null;
      setDeletingId(null);
    }
  };

  /**
   * Turn available-sharing on or off for one existing link.
   *
   * NOTHING IS UPDATED OPTIMISTICALLY. The switch keeps showing the server's
   * value until the list has been refetched, so what the owner reads is always
   * what the database holds -- the one property that matters for a control that
   * decides how much of their calendar strangers can see. The cost is that the
   * switch does not move until the round trip completes, which is why it is
   * disabled rather than left looking unresponsive.
   *
   * The three outcomes are kept apart on purpose:
   *   true   the setting is now `next`; the refreshed row shows it.
   *   false  nothing changed and nothing failed (see the call site below). The
   *          list is still refreshed, because the most likely cause is that the
   *          row is no longer active and the list is out of date.
   *   throw  the call did not land -- 28000 from an expired session, or the
   *          network. The list is left exactly as it was, so the owner is still
   *          looking at the link they were acting on, and nothing is retried.
   */
  const handleToggleAvailable = async (l: ShareLink) => {
    if (togglingRef.current !== null || deletingRef.current !== null) return;
    const next = !l.shareAvailable;
    togglingRef.current = l.id;
    setError(null);
    setNotice(null);
    setConfirmingDeleteId(null);
    setTogglingId(l.id);
    try {
      const applied = await setShareAvailable(l.id, next);
      await refresh();
      if (!applied) setNotice('shareDialog.availableRefused');
    } catch (e) {
      setError({ kind: 'caught', cause: e });
    } finally {
      togglingRef.current = null;
      setTogglingId(null);
    }
  };

  const handleCopy = async () => {
    if (!justCreated) return;
    try {
      await navigator.clipboard.writeText(shareUrl(justCreated.token));
      setCopied(true);
    } catch {
      setCopied(false);
    }
  };

  const now = Date.now();
  const visible = visibleShareLinks(links, revokedOnly);

  const body = (
    <>
        {justCreated && (
          <div className="share-created" role="status">
            <p className="share-created-title">{tr('shareDialog.created.title')}</p>
            <div className="share-url-row">
              <input className="share-url" readOnly value={shareUrl(justCreated.token)} onFocus={(e) => e.target.select()} />
              <button className="btn" onClick={handleCopy}>{copied ? tr('shareDialog.created.copied') : tr('shareDialog.created.copy')}</button>
            </div>
            <p className="share-warn">
              {tr('shareDialog.created.warnBefore')}
              <strong>{tr('shareDialog.created.warnEmphasis')}</strong>
              {tr('shareDialog.created.warnAfter')}
            </p>
          </div>
        )}

        <div className="share-form">
          <label className="field">
            <span>{tr('shareDialog.label')}</span>
            <input
              value={label}
              onChange={(e) => setLabel(e.target.value)}
              placeholder={tr('shareDialog.labelPlaceholder')}
              maxLength={SHARE_LABEL_MAX}
            />
          </label>
          {/* Outside the label on purpose, so a count that changes on every
              keystroke stays out of the input's accessible name. It reports the
              TRIMMED length, which is what gets saved and what validation
              counts, so it can read one short of maxLength while the field has
              stopped accepting whitespace. */}
          <p className="form-hint">
            {shareLabelLength(label)} / {SHARE_LABEL_MAX}
          </p>
          <label className="field checkbox">
            <input type="checkbox" checked={includePrivate} onChange={(e) => setIncludePrivate(e.target.checked)} />
            <span>{tr('shareDialog.includePrivate')}</span>
          </label>
          {/* A SECOND, INDEPENDENT disclosure, not a refinement of the one
              above. include_private decides whether private events count
              towards busy at all; this decides whether time the owner marked
              available is published. All four combinations are legal and the
              database treats them as orthogonal, so the two sit as two plain
              checkboxes with no nesting or disabling between them. */}
          <label className="field checkbox">
            <input
              type="checkbox"
              checked={shareAvailableNew}
              onChange={(e) => setShareAvailableNew(e.target.checked)}
            />
            <span>{tr('shareDialog.shareAvailable')}</span>
          </label>
          <p className="form-hint">
            {tr('shareDialog.shareAvailableHint')}
          </p>
          <label className="field">
            <span>{tr('shareDialog.expiresAt')}</span>
            <input
              type="datetime-local"
              ref={expiryInputRef}
              value={expiresLocal}
              aria-invalid={expiry.kind === 'gap' || expiryMessage !== null ? true : undefined}
              aria-describedby={expiryDescribedBy}
              onChange={(e) => {
                setExpiresLocal(e.target.value);
                setExpiryPick(null);
              }}
            />
          </label>
          {(expiry.kind === 'gap' || expiryFoldCheck) && (
            <div id="share-expiry-dst">
              <WallTimeNotice
                name="share-expiry"
                fieldLabel={tr('shareDialog.expiresAt')}
                local={expiresLocal}
                check={expiry.kind === 'gap' ? expiry.check : expiryFoldCheck!}
                choice={expiry.kind === 'instant' || expiry.kind === 'past' ? (expiry.fold?.choice ?? null) : null}
                onChoose={(choice) => setExpiryPick({ local: expiresLocal, timeZone, choice })}
              />
            </div>
          )}
          {expiryMessage && (
            <p id="share-expiry-error" className="form-error" role="alert">
              {expiryMessage}
            </p>
          )}
          <button className="btn primary" onClick={handleCreate} disabled={creating || busy}>
            {creating ? tr('shareDialog.creating') : tr('shareDialog.create')}
          </button>
        </div>

        {error && <p className="form-error">{shareDialogErrorText(error, language)}</p>}
        {notice && <p className="share-notice" role="status">{tr(notice)}</p>}

        <div className="share-list">
          <div className="share-list-head">
            <h4 className="share-list-title">{tr('shareDialog.list.title')}</h4>
            <label className="share-filter">
              <input
                type="checkbox"
                checked={revokedOnly}
                onChange={(e) => {
                  setRevokedOnly(e.target.checked);
                  setConfirmingDeleteId(null);
                }}
              />
              <span>{tr('shareDialog.list.revokedOnly')}</span>
            </label>
          </div>
          {loading ? (
            <p className="freebusy-loading">{tr('sharePage.loading')}</p>
          ) : links.length === 0 ? (
            <p className="share-empty">{tr('shareDialog.list.empty')}</p>
          ) : visible.length === 0 ? (
            <p className="share-empty">{tr('shareDialog.list.noRevoked')}</p>
          ) : (
            <ul className="share-links">
              {visible.map((l) => {
                const status = shareLinkStatus(l, now);
                const confirming = confirmingDeleteId === l.id;
                const deleting = deletingId === l.id;
                const toggling = togglingId === l.id;
                return (
                  <li
                    key={l.id}
                    className={
                      'share-link-item' +
                      (status === 'active' ? '' : ' inactive') +
                      // .inactive dims the row to 0.6, which is right for a
                      // revoked link at rest and wrong for the moment it is
                      // asking whether to destroy itself. This restores it.
                      (confirming ? ' confirming' : '')
                    }
                  >
                    <div className="share-link-meta">
                      <span className="share-link-label">{l.label || tr('shareDialog.list.noLabel')}</span>
                      <span className="share-link-status">{tr(STATUS_KEY[status])}</span>
                      <span className="share-link-sub">
                        {l.includePrivate ? tr('shareDialog.sub.includePrivate') : tr('shareDialog.sub.excludePrivate')}
                        {` / ${l.shareAvailable ? tr('shareDialog.sub.availableShared') : tr('shareDialog.sub.availableHidden')}`}
                        {l.expiresAt
                          ? ` / ${tr('shareDialog.sub.expiresAt', {
                              at: shareExpiryLabel(l.expiresAt, intlLocale(language), timeZone),
                            })}`
                          : ''}
                      </span>
                      {/* Only on rows 0022 would actually update. An expired or
                          revoked link shows its setting in the line above but
                          offers no switch, because the RPC refuses those with a
                          bare false -- the same reason the delete button is
                          absent from rows 0015 would refuse. */}
                      {canSetShareAvailable(l, now) && (
                        <label className="share-link-toggle">
                          <input
                            type="checkbox"
                            checked={l.shareAvailable}
                            disabled={busy}
                            onChange={() => void handleToggleAvailable(l)}
                          />
                          <span>
                            {tr('shareDialog.toggleAvailable')}
                            {toggling ? tr('shareDialog.toggleUpdating') : ''}
                          </span>
                        </label>
                      )}
                      {status === 'expired' && (
                        <span className="share-link-hint">
                          {tr('shareDialog.expiredHint')}
                        </span>
                      )}
                    </div>
                    {!confirming &&
                      (canDeleteShareLink(l) ? (
                        <button
                          className="btn danger"
                          disabled={busy}
                          onClick={() => {
                            setNotice(null);
                            setConfirmingDeleteId(l.id);
                          }}
                        >
                          {tr('shareDialog.delete')}
                        </button>
                      ) : (
                        <button
                          className="btn danger"
                          disabled={busy || revokingId === l.id}
                          onClick={() => handleRevoke(l.id)}
                        >
                          {tr('shareDialog.revoke')}
                        </button>
                      ))}
                    {confirming && (
                      <div className="share-link-confirm">
                        <p className="share-link-confirm-text">{tr('shareDialog.confirmDelete')}</p>
                        <div className="share-link-confirm-actions">
                          <button className="btn danger" disabled={busy} onClick={() => handleDelete(l.id)}>
                            {deleting ? tr('shareDialog.deleting') : tr('shareDialog.deleteConfirm')}
                          </button>
                          <button className="btn" disabled={busy} onClick={() => setConfirmingDeleteId(null)}>
                            {tr('common.cancel')}
                          </button>
                        </div>
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
          <p className="share-note">
            {tr('shareDialog.note.urlOnce')}
          </p>
          <p className="share-note">
            <strong>{tr('shareDialog.note.revokeTerm')}</strong>{tr('shareDialog.note.revokeBody')}
            <strong>{tr('shareDialog.note.deleteTerm')}</strong>{tr('shareDialog.note.deleteBody')}
          </p>
        </div>

    </>
  );

  /*
    THE SHEET, BECAUSE THIS SCREEN GROWS.

    P8-b3 built .sheet-* for the event form and this reuses it -- but not
    because reuse is free. It fits HERE for the reason it fitted there: the
    content has no bound. A create form sits above a list of every live link,
    and an owner with several links scrolls past all of them to reach close.
    The settings dialog next door is two fields and does NOT get this; a
    full-height sheet for two fields is a worse screen, not a more consistent
    one.

    Close sits in the header for the same reason save did: it is the way out,
    and the way out should not be below an unbounded list.
  */
  if (isMobile) {
    return (
      <div className="sheet-backdrop">
        <div className="sheet" role="dialog" aria-modal="true" aria-label={tr('shareDialog.title')}>
          <div className="sheet-header">
            <h2 className="sheet-title">{tr('shareDialog.title')}</h2>
            <button className="btn" onClick={onClose}>{tr('common.close')}</button>
          </div>
          <div className="sheet-body">{body}</div>
        </div>
      </div>
    );
  }

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true">
        <h3 className="modal-title">{tr('shareDialog.title')}</h3>

        {body}

        <div className="modal-actions">
          <div className="spacer" />
          <button className="btn" onClick={onClose}>{tr('common.close')}</button>
        </div>
      </div>
    </div>
  );
}
