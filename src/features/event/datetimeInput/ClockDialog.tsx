import { useLayoutEffect, useRef, useState, type KeyboardEvent, type PointerEvent } from 'react';
import { useTranslate } from '../../../i18n/useLanguage';
import {
  C, HOURS_INNER, HOURS_OUTER, MINUTE_LABELS, R_OUTER, SIZE,
  hourAt, hourPos, minuteAt, minutePos, nearestTurn, pad2, xy,
} from './clockGeometry';
import { overlayKeyHandler, useReturnFocus, useVisualViewportBox } from './overlayHooks';

export type ClockMode = 'dial' | 'text';

interface Props {
  /** Committed "HH:mm" the dialog opens on. */
  value: string;
  /** Accessible name: the time field's own label, e.g. "Start Time". */
  title: string;
  initialMode: ClockMode;
  onConfirm: (hhmm: string, mode: ClockMode) => void;
  onCancel: (mode: ClockMode) => void;
}

type View = 'hours' | 'minutes';

/**
 * Material-style 24-hour analog time picker for the mobile layout, ported
 * from the approved P8-b5.6b-1 prototype.
 *
 * THE DRAFT IS LOCAL. Nothing the dial does reaches the form until OK;
 * Cancel, Esc and a tap on the backdrop all discard it. Mounted only while
 * open, so every opening starts from the committed value.
 *
 * A TAP on the minute dial snaps to the nearest 5 (one minute is 6 degrees,
 * about 11px on a phone -- an aimed tap missed a labelled minute in the
 * prototype); a DRAG keeps 1-minute precision, and ±1 and the text mode reach
 * any minute.
 */
export function ClockDialog({ value, title, initialMode, onConfirm, onCancel }: Props) {
  const tr = useTranslate();
  const [h0, m0] = value.split(':').map(Number) as [number, number];
  const [hour, setHour] = useState(Number.isFinite(h0) ? h0 : 0);
  const [minute, setMinute] = useState(Number.isFinite(m0) ? m0 : 0);
  const [view, setView] = useState<View>('hours');
  const [mode, setMode] = useState<ClockMode>(initialMode);
  const [dragging, setDragging] = useState(false);
  const [hText, setHText] = useState(pad2(hour));
  const [mText, setMText] = useState(pad2(minute));
  const panelRef = useRef<HTMLDivElement>(null);
  const dialRef = useRef<SVGSVGElement>(null);
  const hInputRef = useRef<HTMLInputElement>(null);
  const mInputRef = useRef<HTMLInputElement>(null);
  const turnRef = useRef(0);
  const downAt = useRef<{ x: number; y: number } | null>(null);
  const vv = useVisualViewportBox(true);
  useReturnFocus();

  useLayoutEffect(() => {
    if (mode === 'text') {
      hInputRef.current?.focus();
      hInputRef.current?.select();
    } else {
      dialRef.current?.focus();
    }
  }, [mode]);

  const textValid =
    /^\d{1,2}$/.test(hText) && /^\d{1,2}$/.test(mText) && Number(hText) <= 23 && Number(mText) <= 59;

  const switchMode = () => {
    if (mode === 'dial') {
      setHText(pad2(hour));
      setMText(pad2(minute));
      setMode('text');
    } else {
      if (textValid) {
        setHour(Number(hText));
        setMinute(Number(mText));
      }
      setMode('dial');
    }
  };

  const confirm = () => {
    if (mode === 'text') {
      if (!textValid) return;
      onConfirm(`${pad2(Number(hText))}:${pad2(Number(mText))}`, mode);
    } else {
      onConfirm(`${pad2(hour)}:${pad2(minute)}`, mode);
    }
  };

  const toDial = (e: PointerEvent<SVGSVGElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    return { x: ((e.clientX - rect.left) / rect.width) * SIZE, y: ((e.clientY - rect.top) / rect.height) * SIZE };
  };
  const pick = (e: PointerEvent<SVGSVGElement>) => {
    const { x, y } = toDial(e);
    if (view === 'hours') setHour(hourAt(x, y));
    else setMinute(minuteAt(x, y));
  };
  const onPointerDown = (e: PointerEvent<SVGSVGElement>) => {
    e.currentTarget.setPointerCapture(e.pointerId);
    downAt.current = { x: e.clientX, y: e.clientY };
    setDragging(true);
    pick(e);
  };
  const onPointerUp = (e: PointerEvent<SVGSVGElement>) => {
    if (!dragging) return;
    setDragging(false);
    const d = downAt.current;
    const isTap = d !== null && Math.hypot(e.clientX - d.x, e.clientY - d.y) < 8;
    if (isTap && view === 'minutes') {
      const { x, y } = toDial(e);
      setMinute((Math.round(minuteAt(x, y) / 5) * 5) % 60);
    }
    // Material's flow: lifting the finger on an hour moves on to minutes.
    if (view === 'hours') setView('minutes');
  };

  const onDialKey = (e: KeyboardEvent) => {
    const step = (d: number) => {
      e.preventDefault();
      if (view === 'hours') setHour((h) => (((h + d) % 24) + 24) % 24);
      else setMinute((m) => (((m + d) % 60) + 60) % 60);
    };
    if (e.key === 'ArrowUp' || e.key === 'ArrowRight') step(1);
    else if (e.key === 'ArrowDown' || e.key === 'ArrowLeft') step(-1);
    else if (e.key === 'PageUp') step(5);
    else if (e.key === 'PageDown') step(-5);
    else if (e.key === 'Enter') {
      e.preventDefault();
      if (view === 'hours') setView('minutes');
      else confirm();
    }
  };
  const onTextKey = (e: KeyboardEvent<HTMLInputElement>) => {
    // preventDefault: the same Enter would otherwise reach the tap target that
    // focus returns to and reopen the clock (measured in the prototype).
    if (e.key === 'Enter') {
      e.preventDefault();
      confirm();
    }
  };

  const sel = view === 'hours' ? hourPos(hour) : minutePos(minute);
  turnRef.current = nearestTurn(turnRef.current, sel.deg);
  const knob = xy({ deg: 0, r: sel.r });
  const onLabel = view === 'hours' || minute % 5 === 0;
  const labels =
    view === 'hours'
      ? [
          ...HOURS_OUTER.map((h) => ({ v: h, p: hourPos(h), inner: false })),
          ...HOURS_INNER.map((h) => ({ v: h, p: hourPos(h), inner: true })),
        ]
      : MINUTE_LABELS.map((m) => ({ v: m, p: minutePos(m), inner: false }));
  const selected = view === 'hours' ? hour : minute;
  const fromFullWidth = (v: string) => v.replace(/[０-９]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xfee0));

  return (
    <div
      className={`dt-overlay is-sheet dt-clock-overlay${mode === 'text' ? ' is-text' : ''}`}
      style={vv ? { top: vv.top, height: vv.height, bottom: 'auto' } : undefined}
      onPointerDown={(e) => {
        if (e.target === e.currentTarget) onCancel(mode);
      }}
    >
      <div
        ref={panelRef}
        className="dt-clock"
        role="dialog"
        aria-modal="true"
        aria-label={title}
        onKeyDown={overlayKeyHandler(panelRef, () => onCancel(mode))}
      >
        <div className="form-hint">{title}</div>
        {mode === 'dial' ? (
          <>
            <div className="dt-clock-readout">
              <button
                type="button"
                className={`dt-clock-seg${view === 'hours' ? ' is-active' : ''}`}
                aria-pressed={view === 'hours'}
                aria-label={tr('event.dt.clock.hours')}
                onClick={() => setView('hours')}
              >
                {pad2(hour)}
              </button>
              <span className="dt-clock-colon">:</span>
              <button
                type="button"
                className={`dt-clock-seg${view === 'minutes' ? ' is-active' : ''}`}
                aria-pressed={view === 'minutes'}
                aria-label={tr('event.dt.clock.minutes')}
                onClick={() => setView('minutes')}
              >
                {pad2(minute)}
              </button>
            </div>
            <div className="dt-clock-face-wrap">
              <svg
                ref={dialRef}
                className={`dt-clock-face${dragging ? ' is-dragging' : ''}`}
                viewBox={`0 0 ${SIZE} ${SIZE}`}
                tabIndex={0}
                role="slider"
                aria-label={view === 'hours' ? tr('event.dt.clock.hours') : tr('event.dt.clock.minutes')}
                aria-valuemin={0}
                aria-valuemax={view === 'hours' ? 23 : 59}
                aria-valuenow={selected}
                aria-valuetext={pad2(selected)}
                onPointerDown={onPointerDown}
                onPointerMove={(e) => dragging && pick(e)}
                onPointerUp={onPointerUp}
                onPointerCancel={() => setDragging(false)}
                onKeyDown={onDialKey}
              >
                <circle cx={C} cy={C} r={C - 2} className="dt-clock-bg" />
                {view === 'minutes' &&
                  Array.from({ length: 60 }, (_, m) => {
                    if (m % 5 === 0) return null;
                    const a = xy({ deg: m * 6, r: R_OUTER + 14 });
                    const b = xy({ deg: m * 6, r: R_OUTER + 9 });
                    return <line key={m} x1={a.x} y1={a.y} x2={b.x} y2={b.y} className="dt-clock-tick" />;
                  })}
                <g className="dt-clock-hand" style={{ transform: `rotate(${turnRef.current}deg)` }}>
                  <line x1={C} y1={C} x2={knob.x} y2={knob.y} />
                  <circle cx={knob.x} cy={knob.y} r={onLabel ? 17 : 5} className="dt-clock-knob" />
                </g>
                <circle cx={C} cy={C} r={3} className="dt-clock-center" />
                {labels.map(({ v, p, inner }) => {
                  const { x, y } = xy(p);
                  return (
                    <text
                      key={`${inner ? 'i' : 'o'}${v}`}
                      x={x}
                      y={y}
                      className={`dt-clock-num${inner ? ' is-inner' : ''}${v === selected ? ' is-selected' : ''}`}
                    >
                      {view === 'hours' ? (v === 0 ? '00' : v) : pad2(v)}
                    </text>
                  );
                })}
              </svg>
            </div>
            {view === 'minutes' && (
              <div className="dt-clock-fine">
                <button type="button" className="btn" aria-label={tr('event.dt.clock.minus1')} onClick={() => setMinute((m) => (m + 59) % 60)}>
                  −1
                </button>
                <span className="form-hint">{tr('event.dt.clock.minutes')}</span>
                <button type="button" className="btn" aria-label={tr('event.dt.clock.plus1')} onClick={() => setMinute((m) => (m + 1) % 60)}>
                  +1
                </button>
              </div>
            )}
          </>
        ) : (
          <div className="dt-clock-text">
            <label className="field">
              <span>
                {tr('event.dt.clock.hours')} <small>({tr('event.dt.clock.hourRange')})</small>
              </span>
              <input
                ref={hInputRef}
                inputMode="numeric"
                autoComplete="off"
                maxLength={2}
                value={hText}
                aria-invalid={!/^\d{1,2}$/.test(hText) || Number(hText) > 23}
                onChange={(e) => {
                  const v = fromFullWidth(e.target.value);
                  setHText(v);
                  if (/^\d{2}$/.test(v)) mInputRef.current?.focus();
                }}
                onFocus={(e) => e.target.select()}
                onKeyDown={onTextKey}
              />
            </label>
            <span className="dt-clock-colon">:</span>
            <label className="field">
              <span>
                {tr('event.dt.clock.minutes')} <small>({tr('event.dt.clock.minuteRange')})</small>
              </span>
              <input
                ref={mInputRef}
                inputMode="numeric"
                autoComplete="off"
                maxLength={2}
                value={mText}
                aria-invalid={!/^\d{1,2}$/.test(mText) || Number(mText) > 59}
                onChange={(e) => setMText(fromFullWidth(e.target.value))}
                onFocus={(e) => e.target.select()}
                onKeyDown={onTextKey}
              />
            </label>
          </div>
        )}
        {mode === 'text' && !textValid && <p className="form-error">{tr('event.dt.time.format')}</p>}
        <div className="dt-actions">
          <button type="button" className="btn dt-quiet" onClick={switchMode}>
            {mode === 'dial' ? tr('event.dt.toText') : tr('event.dt.toDial')}
          </button>
          <span className="dt-spacer" />
          <button type="button" className="btn" onClick={() => onCancel(mode)}>{tr('common.cancel')}</button>
          <button type="button" className="btn primary" disabled={mode === 'text' && !textValid} onClick={confirm}>
            {tr('event.dt.confirm')}
          </button>
        </div>
      </div>
    </div>
  );
}
