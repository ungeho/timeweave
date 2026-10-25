import { useTranslate } from '../../i18n/useLanguage';
import { formatUtcOffset, type FoldChoice, type WallTimeCheck } from './formInstant';

interface Props {
  /** "開始" / "終了" -- which field this is about. */
  fieldLabel: string;
  /** The field's "YYYY-MM-DDTHH:mm". */
  local: string;
  check: WallTimeCheck;
  choice: FoldChoice | null;
  onChoose: (choice: FoldChoice) => void;
  /** Distinguishes the start's radio group from the end's. */
  name: string;
}

/**
 * What the form says about a wall clock that does not name exactly one
 * instant (docs/p8-datetime-contract.md). Renders nothing for a normal time.
 *
 *   gap  -- why it does not exist and what the clock does instead; the value
 *           is NOT rewritten, the owner changes it.
 *   fold -- the two instants, each with its UTC offset (and abbreviation when
 *           the zone has one), as a radio pair. The choice is saved as that
 *           instant and recovered from it when the event is reopened.
 */
export function WallTimeNotice({ fieldLabel, local, check, choice, onChoose, name }: Props) {
  const tr = useTranslate();
  if (check.kind === 'normal') return null;
  const hm = (l: string) => l.slice(11, 16);

  if (check.kind === 'gap') {
    return (
      <p className="form-error dt-wall-notice" role="alert">
        <strong>{fieldLabel}: </strong>
        {tr('event.dt.dst.gap', {
          date: local.slice(0, 10),
          before: hm(check.lastBefore),
          after: hm(check.firstAfter),
          minutes: String(check.gapMinutes),
        })}
      </p>
    );
  }

  return (
    <fieldset className="dt-wall-notice dt-fold">
      <legend>
        <strong>{fieldLabel}: </strong>
        {tr('event.dt.dst.fold')}
      </legend>
      {check.options.map((o) => (
        <label key={o.choice} className="field checkbox dt-fold-option">
          <input type="radio" name={name} checked={choice === o.choice} onChange={() => onChoose(o.choice)} />
          <span>
            {tr(o.choice === 'earlier' ? 'event.dt.dst.first' : 'event.dt.dst.second')} {hm(local)}
            {o.abbreviation ? ` ${o.abbreviation}` : ''} ({formatUtcOffset(o.offsetMinutes)})
          </span>
        </label>
      ))}
    </fieldset>
  );
}
