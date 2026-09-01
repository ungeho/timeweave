/**
 * Manage Free/Busy share links: create (with include-private + optional expiry),
 * list, and revoke. The plaintext token is shown ONCE right after creation and
 * cannot be retrieved later (only its hash is stored), which the UI states
 * explicitly.
 */

import { useEffect, useState } from 'react';
import {
  createShareLink,
  listShareLinks,
  revokeShareLink,
} from '../../repositories/shareRepository';
import type { CreatedShareLink, ShareLink } from '../../types/share';
import { isoFromDatetimeLocalValue } from '../../utils/datetime';

const shareUrl = (token: string) => `${window.location.origin}/s/${token}`;

export function ShareDialog({ onClose }: { onClose: () => void }) {
  const [links, setLinks] = useState<ShareLink[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [label, setLabel] = useState('');
  const [includePrivate, setIncludePrivate] = useState(true);
  const [expiresLocal, setExpiresLocal] = useState('');
  const [creating, setCreating] = useState(false);
  const [justCreated, setJustCreated] = useState<CreatedShareLink | null>(null);
  const [copied, setCopied] = useState(false);

  const refresh = async () => {
    setLoading(true);
    setError(null);
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
    try {
      await revokeShareLink(id);
      if (justCreated?.id === id) setJustCreated(null);
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
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
          <button className="btn primary" onClick={handleCreate} disabled={creating}>
            {creating ? '作成中…' : 'リンクを作成'}
          </button>
        </div>

        {error && <p className="form-error">{error}</p>}

        <div className="share-list">
          <h4 className="share-list-title">既存のリンク</h4>
          {loading ? (
            <p className="freebusy-loading">読み込み中…</p>
          ) : links.length === 0 ? (
            <p className="share-empty">リンクはまだありません。</p>
          ) : (
            <ul className="share-links">
              {links.map((l) => {
                const revoked = l.revokedAt !== null;
                const expired = l.expiresAt !== null && Date.parse(l.expiresAt) <= Date.now();
                const status = revoked ? '失効済' : expired ? '期限切れ' : '有効';
                return (
                  <li key={l.id} className={`share-link-item${revoked || expired ? ' inactive' : ''}`}>
                    <div className="share-link-meta">
                      <span className="share-link-label">{l.label || '(ラベルなし)'}</span>
                      <span className="share-link-status">{status}</span>
                      <span className="share-link-sub">
                        {l.includePrivate ? 'private含む' : 'private除外'}
                        {l.expiresAt ? ` / 期限 ${new Date(l.expiresAt).toLocaleString()}` : ''}
                      </span>
                    </div>
                    {!revoked && (
                      <button className="btn danger" onClick={() => handleRevoke(l.id)}>失効</button>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
          <p className="share-note">
            既存リンクのURLは再表示できません（作成時のみ表示）。分からなくなった場合は失効して作り直してください。
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
