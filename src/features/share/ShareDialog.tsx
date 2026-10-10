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
import {
  createShareLink,
  deleteShareLink,
  listShareLinks,
  revokeShareLink,
  setShareAvailable,
} from '../../repositories/shareRepository';
import type { CreatedShareLink, ShareLink } from '../../types/share';
import { isoFromDatetimeLocalValue } from '../../utils/datetime';
import { SHARE_LABEL_MAX, labelLengthError, shareLabelLength } from './shareLinkLabel';
import {
  canDeleteShareLink,
  canSetShareAvailable,
  shareLinkStatus,
  visibleShareLinks,
} from './shareLinkState';

const shareUrl = (token: string) => `${window.location.origin}/s/${token}`;

const STATUS_LABEL = { active: '有効', expired: '期限切れ', revoked: '失効済' } as const;

const CONFIRM_DELETE = 'このリンクの記録を完全に削除します。元に戻せません。';

/**
 * 0015 returns false for a row that is absent, someone else's, or still active,
 * without distinguishing them. The delete button only appears on the owner's
 * revoked rows, so in practice this means the row is already gone -- another
 * tab, most likely. It is not a failure, so it is not shown as an error.
 */
const DELETE_REFUSED = 'このリンクはすでに削除されたか、削除できない状態です。一覧を更新しました。';

/**
 * 0022 returns false for a row that is absent, someone else's, revoked or
 * expired, without distinguishing them -- the same deliberate opacity 0015 has.
 * The toggle is only rendered on the owner's ACTIVE rows, so in practice this
 * means the row stopped being active between the render and the click: expired
 * on its own, or revoked in another tab.
 *
 * It is NOT reported as an error, because nothing failed; and it is NOT treated
 * as success, because the setting did not change. The list is refreshed so the
 * row redraws in whatever state it is actually in, and the switch returns to
 * the server's value rather than the one that was clicked.
 */
const AVAILABLE_REFUSED =
  'このリンクの設定を変更できませんでした。期限切れか失効している可能性があります。一覧を更新しました。';

export function ShareDialog({ onClose }: { onClose: () => void }) {
  const [links, setLinks] = useState<ShareLink[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const [label, setLabel] = useState('');
  const [includePrivate, setIncludePrivate] = useState(true);
  // Defaults to OFF, unlike includePrivate. Sharing busy time is what a share
  // link is for, so including private events in it is the expected shape; open
  // time is a second, additive disclosure the owner has to choose.
  const [shareAvailableNew, setShareAvailableNew] = useState(false);
  const [expiresLocal, setExpiresLocal] = useState('');
  const [creating, setCreating] = useState(false);
  const [justCreated, setJustCreated] = useState<CreatedShareLink | null>(null);
  const [copied, setCopied] = useState(false);

  const [revokedOnly, setRevokedOnly] = useState(false);
  const [confirmingDeleteId, setConfirmingDeleteId] = useState<string | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [togglingId, setTogglingId] = useState<string | null>(null);

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
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void refresh();
  }, []);

  const handleCreate = async () => {
    setError(null);
    setNotice(null);
    setConfirmingDeleteId(null);
    setCopied(false);
    // Normally unreachable through this input, which enforces the same product
    // limit with maxLength. The rule is stated once more at the submit boundary
    // for programmatic values and future input paths. The database's 200-byte
    // CHECK is a separate storage bound -- 50 UTF-16 units occupy at most 150
    // UTF-8 bytes, so it cannot fire for anything this guard accepts.
    const tooLong = labelLengthError(label);
    if (tooLong) {
      setError(tooLong);
      return;
    }
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
        expiresAt: expiresLocal ? isoFromDatetimeLocalValue(expiresLocal) : null,
        shareAvailable: shareAvailableNew,
      });
      setJustCreated(created);
      setLabel('');
      setExpiresLocal('');
      // includePrivate and shareAvailable deliberately KEEP their values: an
      // owner creating several links usually wants the same disclosure settings
      // for them, and resetting would quietly turn the choice off between two
      // creations.
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setCreating(false);
    }
  };

  const handleRevoke = async (id: string) => {
    setError(null);
    setNotice(null);
    setConfirmingDeleteId(null);
    try {
      await revokeShareLink(id);
      if (justCreated?.id === id) setJustCreated(null);
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
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
      if (!deleted) setNotice(DELETE_REFUSED);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
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
   *   false  nothing changed and nothing failed (see AVAILABLE_REFUSED). The
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
      if (!applied) setNotice(AVAILABLE_REFUSED);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
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

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true">
        <h3 className="modal-title">空き時間を共有</h3>

        {justCreated && (
          <div className="share-created" role="status">
            <p className="share-created-title">共有リンクを作成しました</p>
            <div className="share-url-row">
              <input className="share-url" readOnly value={shareUrl(justCreated.token)} onFocus={(e) => e.target.select()} />
              <button className="btn" onClick={handleCopy}>{copied ? 'コピー済' : 'コピー'}</button>
            </div>
            <p className="share-warn">
              このURLは<strong>今だけ</strong>表示されます。閉じると再表示できません（トークンは保存されません）。
              必要なら今すぐコピーして共有先へ渡してください。
            </p>
          </div>
        )}

        <div className="share-form">
          <label className="field">
            <span>ラベル（任意・管理用）</span>
            <input
              value={label}
              onChange={(e) => setLabel(e.target.value)}
              placeholder="例: 取引先A用"
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
            <span>非公開(private)の予定も busy として含める</span>
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
            <span>「空き時間(Available)」として登録した予定も公開する</span>
          </label>
          <p className="form-hint">
            公開されるのは、予定を「空き時間」として明示的に登録した時間だけです。予定が入っていない時間が自動的に空き時間として公開されることはありません。
          </p>
          <label className="field">
            <span>有効期限（任意）</span>
            <input type="datetime-local" value={expiresLocal} onChange={(e) => setExpiresLocal(e.target.value)} />
          </label>
          <button className="btn primary" onClick={handleCreate} disabled={creating || busy}>
            {creating ? '作成中…' : 'リンクを作成'}
          </button>
        </div>

        {error && <p className="form-error">{error}</p>}
        {notice && <p className="share-notice" role="status">{notice}</p>}

        <div className="share-list">
          <div className="share-list-head">
            <h4 className="share-list-title">既存のリンク</h4>
            <label className="share-filter">
              <input
                type="checkbox"
                checked={revokedOnly}
                onChange={(e) => {
                  setRevokedOnly(e.target.checked);
                  setConfirmingDeleteId(null);
                }}
              />
              <span>失効済みのみ表示</span>
            </label>
          </div>
          {loading ? (
            <p className="freebusy-loading">読み込み中…</p>
          ) : links.length === 0 ? (
            <p className="share-empty">リンクはまだありません。</p>
          ) : visible.length === 0 ? (
            <p className="share-empty">失効済みのリンクはありません。</p>
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
                      <span className="share-link-label">{l.label || '(ラベルなし)'}</span>
                      <span className="share-link-status">{STATUS_LABEL[status]}</span>
                      <span className="share-link-sub">
                        {l.includePrivate ? 'private含む' : 'private除外'}
                        {` / ${l.shareAvailable ? '空き時間を公開' : '空き時間は非公開'}`}
                        {l.expiresAt ? ` / 期限 ${new Date(l.expiresAt).toLocaleString()}` : ''}
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
                            空き時間(Available)を公開
                            {toggling ? '（更新中…）' : ''}
                          </span>
                        </label>
                      )}
                      {status === 'expired' && (
                        <span className="share-link-hint">
                          期限切れですが失効していません。削除するには、先に「失効」してください。
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
                          削除
                        </button>
                      ) : (
                        <button className="btn danger" disabled={busy} onClick={() => handleRevoke(l.id)}>失効</button>
                      ))}
                    {confirming && (
                      <div className="share-link-confirm">
                        <p className="share-link-confirm-text">{CONFIRM_DELETE}</p>
                        <div className="share-link-confirm-actions">
                          <button className="btn danger" disabled={busy} onClick={() => handleDelete(l.id)}>
                            {deleting ? '削除中…' : '削除する'}
                          </button>
                          <button className="btn" disabled={busy} onClick={() => setConfirmingDeleteId(null)}>
                            キャンセル
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
            既存リンクのURLは再表示できません（作成時のみ表示）。分からなくなった場合は失効して作り直してください。
          </p>
          <p className="share-note">
            <strong>失効</strong>はURLを使えなくします。記録は残るため、総数の上限には数えられ続けます。
            <strong>削除</strong>は失効済みリンクの記録そのものを消し、総数の枠を空けます（元に戻せません）。
          </p>
        </div>

        <div className="modal-actions">
          <div className="spacer" />
          <button className="btn" onClick={onClose}>閉じる</button>
        </div>
      </div>
    </div>
  );
}
