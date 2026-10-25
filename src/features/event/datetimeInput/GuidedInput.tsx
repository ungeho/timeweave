import { forwardRef, useState, type ChangeEvent, type InputHTMLAttributes, type SyntheticEvent } from 'react';
import { autoHyphen as autoHyphenStep, guideRemainder } from './dateTimeText';

interface Props extends Omit<InputHTMLAttributes<HTMLInputElement>, 'value' | 'onChange' | 'placeholder'> {
  value: string;
  onValueChange: (v: string) => void;
  /** Format templates; the first is also the placeholder. */
  templates: readonly string[];
  /** Insert "-" after YYYY / YYYY-MM typed at the end (dateTimeText.autoHyphen). */
  autoHyphen?: boolean;
}

/**
 * A plain text input with a faint format guide drawn BEHIND it.
 *
 * THE GUIDE IS NEVER PART OF THE VALUE. It is a separate, aria-hidden layer: a
 * transparent copy of what was typed (so the guide starts exactly where the
 * text ends, whatever the font) followed by the rest of the template, muted.
 * Copy, paste, select-all, screen readers and form state only ever see what
 * the owner typed. The format is announced through aria-describedby instead.
 *
 * It is drawn only when it cannot mislead: focused, no IME composition in
 * progress (the composing text is not in `value` yet), the caret at the end
 * (so it never sits under the caret or beside a middle edit), and the draft
 * following a template. Anything else simply hides it.
 */
export const GuidedInput = forwardRef<HTMLInputElement, Props>(function GuidedInput(
  { value, onValueChange, templates, autoHyphen = false, className, onFocus, onBlur, ...rest },
  ref,
) {
  const [focused, setFocused] = useState(false);
  const [composing, setComposing] = useState(false);
  const [caretAtEnd, setCaretAtEnd] = useState(true);

  const trackCaret = (e: SyntheticEvent<HTMLInputElement>) => {
    const el = e.currentTarget;
    setCaretAtEnd(el.selectionStart === el.value.length && el.selectionEnd === el.value.length);
  };

  const onChange = (e: ChangeEvent<HTMLInputElement>) => {
    const el = e.target;
    const atEnd = el.selectionStart === el.value.length;
    setCaretAtEnd(atEnd);
    if (autoHyphen) {
      const inputType = (e.nativeEvent as InputEvent).inputType ?? '';
      const replaced = autoHyphenStep(value, el.value, inputType, atEnd);
      if (replaced !== null) {
        onValueChange(replaced);
        return;
      }
    }
    onValueChange(el.value);
  };

  const remainder = focused && !composing && caretAtEnd ? guideRemainder(value, templates) : null;

  return (
    <span className="dt-guided">
      <span className="dt-ghost" aria-hidden="true">
        <span className="dt-ghost-typed">{value}</span>
        {remainder && <span className="dt-ghost-rest">{remainder}</span>}
      </span>
      <input
        ref={ref}
        type="text"
        autoComplete="off"
        spellCheck={false}
        {...rest}
        className={`dt-input ${className ?? ''}`}
        value={value}
        placeholder={templates[0]}
        onChange={onChange}
        onSelect={trackCaret}
        onKeyUp={trackCaret}
        onClick={trackCaret}
        onCompositionStart={() => setComposing(true)}
        onCompositionEnd={() => setComposing(false)}
        onFocus={(e) => {
          setFocused(true);
          trackCaret(e);
          onFocus?.(e);
        }}
        onBlur={(e) => {
          setFocused(false);
          onBlur?.(e);
        }}
      />
    </span>
  );
});
