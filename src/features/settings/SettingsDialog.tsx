/**
 * Owner preferences: time zone and display language.
 *
 * THE TWO CONTROLS DO NOT BELONG TO THE SAME WORLD, and the dialog says so
 * rather than leaving the owner to discover it. The zone decides what anonymous
 * viewers are told about the owner's all-day time; the language decides what
 * words this screen uses. They are stored in one row because one row is cheaper
 * than two, not because they are related.
 *
 * The warning before a zone change is not decoration. Changing a zone
 * retroactively reinterprets every all-day event, which can change what a live
 * share link discloses -- so the owner is shown what will happen and has to
 * confirm, the same shape the delete confirmation in ShareDialog uses.
 */

import { useEffect, useRef, useState } from 'react';
import { getOwnerSettings, saveOwnerSettings } from '../../repositories/ownerSettingsRepository';
import type { OwnerSettings, UiLanguage } from '../../types/settings';
import {
  LANGUAGES,
  LANGUAGE_NOT_IN_CALCULATION_NOTICE,
  LANGUAGE_PENDING_NOTICE,
  TIMEZONE_CHANGE_NOTICE,
  TIMEZONE_UNSET_NOTICE,
  browserTimezone,
  timezoneChangeNeedsWarning,
  timezoneOptions,
} from './timezoneSetting';

export function SettingsDialog({ onClose }: { onClose: () => void }) {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  // `saved` is the server's value; `tz`/`lang` are the form. Keeping them apart
  // is what lets the warning compare "what is stored" with "what is about to
  // be stored" rather than with the previous keystroke.
  const [saved, setSaved] = useState<OwnerSettings>({ timezone: null, language: null });
  const [tz, setTz] = useState<string>('');
  const [lang, setLang] = useState<UiLanguage | ''>('');
  const [confirming, setConfirming] = useState(false);
  const [saving, setSaving] = useState(false);
  const savingRef = useRef(false);

  const options = timezoneOptions();

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const s = await getOwnerSettings();
        if (cancelled) return;
        setSaved(s);
        setTz(s.timezone ?? '');
        setLang(s.language ?? '');
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, []);

  const nextTz = tz.trim() === '' ? null : tz.trim();
  const needsWarning = timezoneChangeNeedsWarning(saved.timezone, nextTz);

  /**
   * Nothing is written optimistically: the form keeps showing the server's
   * value until the round trip returns, because this control decides how much
   * of the owner's calendar strangers can see.
   */
  const persist = async () => {
    if (savingRef.current) return;
    savingRef.current = true;
    setSaving(true);
    setError(null);
    setNotice(null);
    try {
      const s = await saveOwnerSettings({
        timezone: nextTz,
        language: lang === '' ? null : lang,
      });
      setSaved(s);
      setTz(s.timezone ?? '');
      setLang(s.language ?? '');
      setConfirming(false);
      setNotice('設定を保存しました。');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      savingRef.current = false;
      setSaving(false);
    }
  };

  const onSave = () => {
    if (needsWarning && !confirming) {
      setNotice(null);
      setConfirming(true);
      return;
    }
    void persist();
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true">
        <h3 className="modal-title">設定</h3>

        {loading ? (
          <p className="freebusy-loading">読み込み中…</p>
        ) : (
          <>
            <div className="share-form">
              <label className="field">
                <span>タイムゾーン</span>
                <input
                  list="tz-options"
                  value={tz}
                  onChange={(e) => { setTz(e.target.value); setConfirming(false); }}
                  placeholder={browserTimezone()}
                  disabled={saving}
                />
              </label>
              <datalist id="tz-options">
                {options.map((z) => <option key={z} value={z} />)}
              </datalist>
              <p className="form-hint">
                終日の予定をどの暦日として扱うかを決めます。空欄にすると未設定に戻ります。
              </p>
              {saved.timezone === null && (
                <p className="form-hint">{TIMEZONE_UNSET_NOTICE}</p>
              )}

              {/* Its own row and its own heading: the language has nothing to do
                  with the zone above it, and a reader who skims must not come
                  away thinking one affects the other. */}
              <label className="field">
                <span>表示言語</span>
                <select
                  value={lang}
                  onChange={(e) => setLang(e.target.value as UiLanguage | '')}
                  disabled={saving}
                >
                  <option value="">ブラウザの設定に従う</option>
                  {LANGUAGES.map((l) => (
                    <option key={l.value} value={l.value}>{l.label}</option>
                  ))}
                </select>
              </label>
              {/* Says the switch is not live yet, BEFORE the user clicks save.
                  The translation layer is a separate phase; without this the
                  owner picks English, sees Japanese, and reasonably concludes
                  the save failed. */}
              <p className="form-hint">{LANGUAGE_PENDING_NOTICE}</p>
              <p className="form-hint">{LANGUAGE_NOT_IN_CALCULATION_NOTICE}</p>
            </div>

            {confirming && (
              <div className="share-link-confirm">
                <p className="share-link-confirm-text">
                  タイムゾーンを変更します。
                </p>
                <ul className="form-hint">
                  {TIMEZONE_CHANGE_NOTICE.map((line) => <li key={line}>{line}</li>)}
                </ul>
                <div className="share-link-confirm-actions">
                  <button className="btn primary" disabled={saving} onClick={() => void persist()}>
                    {saving ? '保存中…' : '変更する'}
                  </button>
                  <button className="btn" disabled={saving} onClick={() => setConfirming(false)}>
                    キャンセル
                  </button>
                </div>
              </div>
            )}

            {error && <p className="form-error">{error}</p>}
            {notice && <p className="share-notice" role="status">{notice}</p>}
          </>
        )}

        <div className="modal-actions">
          <div className="spacer" />
          {!loading && !confirming && (
            <button className="btn primary" disabled={saving} onClick={onSave}>
              {saving ? '保存中…' : '保存'}
            </button>
          )}
          <button className="btn" onClick={onClose}>閉じる</button>
        </div>
      </div>
    </div>
  );
}
