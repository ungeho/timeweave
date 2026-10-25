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
import { useDialogChrome } from '../../hooks/useDialogChrome';
import { getOwnerSettings, saveOwnerSettings } from '../../repositories/ownerSettingsRepository';
import type { OwnerSettings, UiLanguage } from '../../types/settings';
import { useLanguage, useTranslate } from '../../i18n/useLanguage';
import { useAuth } from '../../auth/useAuth';
import { caughtErrorText } from '../../i18n/errorText';
import {
  LANGUAGES,
  browserTimezone,
  languageNotInCalculationNotice,
  timezoneChangeNeedsWarning,
  timezoneChangeNotice,
  timezoneOptions,
  timezoneUnsetNotice,
} from './timezoneSetting';

/**
 * A failed load or save, holding the CAUSE rather than a sentence.
 *
 * Read through `caughtErrorText` at render, which is shared with the calendar
 * banner and the share dialog -- so a DomainError localizes, a plain Error
 * keeps its own message, and anything else gets the generic sentence instead
 * of being stringified onto the screen.
 */
type SettingsError = { readonly cause: unknown };

/**
 * The one thing this dialog says when nothing went wrong, as a KEY.
 *
 * A union of one, not a boolean: the state names what is being said, so adding
 * a second notice later is a new member rather than a second flag. Typed as
 * the literal rather than MessageKey because `t` reads a message's
 * placeholders off the key's literal type.
 */
type SettingsNotice = 'settings.saved';

export function SettingsDialog({ onClose }: { onClose: () => void }) {
  // `language` is what the four notices below are resolved in; it is the
  // DISPLAYED language, which is not the same thing as `lang` further down --
  // that one is the form's pending value for this control. Reading both here is
  // the whole reason this dialog needs useLanguage() rather than useTranslate()
  // alone, and P6 step 3 added the first half of it.
  const { language, setStoredLanguage } = useLanguage();
  const { user } = useAuth();
  const tr = useTranslate();
  const [loading, setLoading] = useState(true);
  // NEITHER OF THESE HOLDS A SENTENCE. Both used to: `error` was filled from
  // `e.message` at a catch and `notice` from `tr(...)` after a save, so both
  // froze their wording at the moment they were set. A language change
  // afterwards re-rendered every other string in this dialog -- including the
  // four notices P6 step 3 converted, right beside them -- and left these two
  // in the old language.
  //
  // A WRAPPER OBJECT RATHER THAN A BARE `unknown`, for the reason useEvents
  // gives: the render test is `error && ...`, and `unknown` includes null, so
  // a `throw null` would have been indistinguishable from "no error" and the
  // line would simply not appear for a failure that did happen. No `kind` tag,
  // though -- unlike ShareDialog there is only ever one variant here, because
  // nothing in this dialog validates input into a message. The zone field is
  // free text and the database has the final word on it.
  const [error, setError] = useState<SettingsError | null>(null);
  const [notice, setNotice] = useState<SettingsNotice | null>(null);

  // `saved` is the server's value; `tz`/`lang` are the form. Keeping them apart
  // is what lets the warning compare "what is stored" with "what is about to
  // be stored" rather than with the previous keystroke.
  const [saved, setSaved] = useState<OwnerSettings>({ timezone: null, language: null });
  const [tz, setTz] = useState<string>('');
  const [lang, setLang] = useState<UiLanguage | ''>('');
  const [confirming, setConfirming] = useState(false);
  const [saving, setSaving] = useState(false);
  const savingRef = useRef(false);
  // Escape is blocked mid-save for the same reason as the other dialogs: the
  // result lands here, and closing would discard it unseen.
  useDialogChrome(onClose, () => savingRef.current);

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
        // The cause, untouched. Still guarded by `cancelled`, so an unmounted
        // dialog still sets nothing.
        if (!cancelled) setError({ cause: e });
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
      // Push the SERVER's value into the language provider so the resolved
      // language updates without a reload. The server's value, not the form's:
      // the save already told us what was stored, so re-fetching would be a
      // second round trip to learn the same thing.
      //
      // Nothing visibly changes yet -- no string reads the language until P3,
      // and the switch is not live until P6. This is the wiring, placed now so
      // that phase does not also have to invent it.
      setStoredLanguage(s.language);
      setTz(s.timezone ?? '');
      setLang(s.language ?? '');
      setConfirming(false);
      setNotice('settings.saved');
    } catch (e) {
      // Only the error is set. `saved` keeps the server's value and the form
      // keeps the owner's selection, so a failed save cannot leave the two
      // confused -- and setStoredLanguage is never reached, so the display
      // language does not move for a save that did not land.
      setError({ cause: e });
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
        <h3 className="modal-title">{tr('settings.title')}</h3>

        {/*
          WHO IS SIGNED IN. The header used to be the only place this
          appeared, and P8-b1 takes it out of the header below 720px -- it was
          the one element making the page scroll sideways on a phone. Putting
          it here keeps it reachable, and this is where the account's other
          settings already are.

          Read from useAuth rather than passed in, so the dialog does not gain
          a prop that only exists to carry a string the context already has.
          Shown only when there IS a session: with auth disabled the dialog
          still opens and this row would be an empty label.
        */}
        {user?.email && (
          <p className="settings-identity">
            <span className="settings-identity-label">{tr('settings.signedInAs')}</span>
            <span className="settings-identity-value">{user.email}</span>
          </p>
        )}

        {loading ? (
          <p className="freebusy-loading">{tr('common.loading')}</p>
        ) : (
          <>
            <div className="share-form">
              <label className="field">
                <span>{tr('settings.timezone.label')}</span>
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
              <p className="form-hint">{tr('settings.timezone.hint')}</p>
              {saved.timezone === null && (
                <p className="form-hint">{timezoneUnsetNotice(language)}</p>
              )}

              {/* Its own row and its own heading: the language has nothing to do
                  with the zone above it, and a reader who skims must not come
                  away thinking one affects the other. */}
              <label className="field">
                <span>{tr('settings.language.label')}</span>
                <select
                  value={lang}
                  onChange={(e) => setLang(e.target.value as UiLanguage | '')}
                  disabled={saving}
                >
                  <option value="">{tr('settings.language.followBrowser')}</option>
                  {LANGUAGES.map((l) => (
                    <option key={l.value} value={l.value}>{l.label}</option>
                  ))}
                </select>
              </label>
              {/* The "not live yet" notice that used to sit here was removed at
                  the end of P6: the switch is on, so a saved language is
                  applied and saying otherwise would be false. This one stays --
                  it is about the Free/Busy computation, not the UI. */}
              <p className="form-hint">{languageNotInCalculationNotice(language)}</p>
            </div>

            {confirming && (
              <div className="share-link-confirm">
                <p className="share-link-confirm-text">{tr('settings.timezone.confirmTitle')}</p>
                <ul className="form-hint">
                  {timezoneChangeNotice(language).map((line) => <li key={line}>{line}</li>)}
                </ul>
                <div className="share-link-confirm-actions">
                  <button className="btn primary" disabled={saving} onClick={() => void persist()}>
                    {saving ? tr('common.saving') : tr('settings.timezone.confirmApply')}
                  </button>
                  <button className="btn" disabled={saving} onClick={() => setConfirming(false)}>
                    {tr('common.cancel')}
                  </button>
                </div>
              </div>
            )}

            {error && <p className="form-error">{caughtErrorText(error.cause, language)}</p>}
            {notice && <p className="share-notice" role="status">{tr(notice)}</p>}
          </>
        )}

        <div className="modal-actions">
          <div className="spacer" />
          {!loading && !confirming && (
            <button className="btn primary" disabled={saving} onClick={onSave}>
              {saving ? tr('common.saving') : tr('common.save')}
            </button>
          )}
          <button className="btn" onClick={onClose}>{tr('common.close')}</button>
        </div>
      </div>
    </div>
  );
}
