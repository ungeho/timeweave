import { describe, expect, it } from 'vitest';
import {
  contentLengthError,
  CATEGORY_MAX,
  DESCRIPTION_MAX,
  TITLE_MAX,
} from './contentLimits';

/** Content as readForm assembles it, with one field overridden per case. */
const content = (over: Partial<Parameters<typeof contentLengthError>[0]> = {}) => ({
  title: '打ち合わせ',
  description: null,
  category: null,
  ...over,
});

describe('contentLengthError — the limit is inclusive at both ends of the boundary', () => {
  it('accepts a value of exactly the limit', () => {
    expect(contentLengthError(content({ title: 'あ'.repeat(TITLE_MAX) }))).toBeNull();
    expect(contentLengthError(content({ category: 'あ'.repeat(CATEGORY_MAX) }))).toBeNull();
    expect(contentLengthError(content({ description: 'あ'.repeat(DESCRIPTION_MAX) }))).toBeNull();
  });

  it('rejects one character past the limit, naming the field', () => {
    expect(contentLengthError(content({ title: 'あ'.repeat(TITLE_MAX + 1) })))
      .toContain('タイトル');
    expect(contentLengthError(content({ category: 'あ'.repeat(CATEGORY_MAX + 1) })))
      .toContain('カテゴリ');
    expect(contentLengthError(content({ description: 'あ'.repeat(DESCRIPTION_MAX + 1) })))
      .toContain('メモ');
  });

  it('reports the title first when several fields are over at once', () => {
    // One message drives one .form-error line, so the order has to be fixed.
    const err = contentLengthError({
      title: 'あ'.repeat(TITLE_MAX + 1),
      category: 'あ'.repeat(CATEGORY_MAX + 1),
      description: 'あ'.repeat(DESCRIPTION_MAX + 1),
    });
    expect(err).toContain('タイトル');
  });
});

describe('contentLengthError — absent optional fields have no length to check', () => {
  it('accepts null description and category', () => {
    expect(contentLengthError(content({ description: null, category: null }))).toBeNull();
  });

  it('accepts empty strings, which readForm turns into null before it gets here', () => {
    expect(contentLengthError(content({ description: '', category: '' }))).toBeNull();
  });

  it('says nothing about an empty title — required-ness is readForm\'s rule, not this one', () => {
    // The dialog rejects a blank title before calling this; keeping the two
    // rules apart means neither has to know the other's message.
    expect(contentLengthError(content({ title: '' }))).toBeNull();
  });
});

describe('contentLengthError — counting matches the maxLength attribute, not the eye', () => {
  it('counts a non-BMP character as the two UTF-16 units the browser counts', () => {
    // 😀 is U+1F600, one code point, one glyph, but "😀".length === 2 in JS and
    // in HTML maxlength. PostgreSQL's char_length would call it 1 -- so a value
    // this function accepts is never too long for the database.
    expect('😀'.length).toBe(2);
    const halfLimitEmoji = '😀'.repeat(TITLE_MAX / 2);
    expect(halfLimitEmoji.length).toBe(TITLE_MAX);
    expect(contentLengthError(content({ title: halfLimitEmoji }))).toBeNull();

    expect(contentLengthError(content({ title: halfLimitEmoji + '😀' })))
      .toContain('タイトル');
  });

  it('counts a multi-code-point grapheme by its units too', () => {
    // A ZWJ family sequence renders as one glyph but is 11 UTF-16 units.
    const family = '👨‍👩‍👧‍👦';
    expect(family.length).toBe(11);
    expect(contentLengthError(content({ category: family.repeat(4) }))).toBeNull(); // 44
    expect(contentLengthError(content({ category: family.repeat(5) }))).toContain('カテゴリ'); // 55
  });
});

describe('the limits themselves', () => {
  it('are the agreed values, which the dialog and the DB constraint both mirror', () => {
    expect(TITLE_MAX).toBe(200);
    expect(CATEGORY_MAX).toBe(50);
    expect(DESCRIPTION_MAX).toBe(2000);
  });
});
