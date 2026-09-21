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
 * it, because the project has no component-test environment.
 */

import { useEffect, useRef, useState } from 'react';
import {
  createShareLink,
  deleteShareLink,
  listShareLinks,
  revokeShareLink,
} from '../../repositories/shareRepository';
import type { CreatedShareLink, ShareLink } from '../../types/share';
import { isoFromDatetimeLocalValue } from '../../utils/datetime';
import { canDeleteShareLink, shareLinkStatus, visibleShareLinks } from './shareLinkState';

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

export function ShareDialog({ onClose }: { onClose: () => void }) {
  const [links, setLinks] = useState<ShareLink[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const [label, setLabel] = useState('');
  const [includePrivate, setIncludePrivate] = useState(true);
  const [expiresLocal, setExpiresLocal] = useState('');
  const [creating, setCreating] = useState(false);
  const [justCreated, setJustCreated] = useState<CreatedShareLink | null>(null);
  const [copied, setCopied] = useState(false);

  const [revokedOnly, setRevokedOnly] = useState(false);
  const [confirmingDeleteId, setConfirmingDeleteId] = useState<string | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);

  // A delete in flight disables every other mutating control, so a second
  // request can never be issued against a list that is about to be replaced.
  const busy = deletingId !== null;
  const deletingRef = useRef<string | null>(null);

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
    setCreating(true);
    setError(null);
    setNotice(null);
    setConfirmingDeleteId(null);
    setCopied(false);
    try {
      const created = await createShareLink({
        label: label.trim() || null,
        includePrivate,
        expiresAt: expiresLocal ? isoFromDatetimeLocalValue(expiresLocal) : null,
      });
      setJustCreated(created);
      setLabel('');
      setExpiresLocal('');
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
            <input value={label} onChange={(e) => setLabel(e.target.value)} placeholder="例: 取引先A用" />
          </label>
          <label className="field checkbox">
            <input type="checkbox" checked={includePrivate} onChange={(e) => setIncludePrivate(e.target.checked)} />
            <span>非公開(private)の予定も busy として含める</span>
          </label>
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
                        {l.expiresAt ? ` / 期限 ${new Date(l.expiresAt).toLocaleString()}` : ''}
                      </span>
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
