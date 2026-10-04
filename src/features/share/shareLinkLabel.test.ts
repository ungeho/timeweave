import { describe, expect, it } from 'vitest';
import { SHARE_LABEL_MAX, labelLengthError, shareLabelLength } from './shareLinkLabel';

/**
 * These pin the share-link label's product limit and, more importantly, the
 * reason it can coexist with migration 0014's `octet_length(label) <= 200`
 * without ever colliding with it. The byte-safety group at the bottom is the
 * one that would catch a future raise of SHARE_LABEL_MAX past what the database
 * CHECK can hold.
 *
 * The policy is UTF-16 code units, NOT grapheme clusters. Several cases below
 * assert that a visually short label can still be refused; that is the known
 * and accepted cost of the unit, not a defect to fix here.
 */

const MESSAGE = `ラベルは${SHARE_LABEL_MAX}文字以内で入力してください`;

describe('shareLabelLength — absent, empty and whitespace-only all measure 0', () => {
  it('treats every form of "no label" as length 0', () => {
    // `label.trim() || null` in the dialog turns all of these into the same
    // stored NULL, so they are the same length here.
    expect(shareLabelLength(null)).toBe(0);
    expect(shareLabelLength(undefined)).toBe(0);
    expect(shareLabelLength('')).toBe(0);
    expect(shareLabelLength('   ')).toBe(0);
    expect(shareLabelLength(' \t\n\r ')).toBe(0);
  });

  it('accepts every one of them', () => {
    expect(labelLengthError(null)).toBeNull();
    expect(labelLengthError(undefined)).toBeNull();
    expect(labelLengthError('')).toBeNull();
    expect(labelLengthError('   ')).toBeNull();
    expect(labelLengthError(' \t\n\r ')).toBeNull();
  });
});

describe('the boundary is inclusive', () => {
  it('accepts exactly the limit and refuses one unit more, in ASCII', () => {
    expect(shareLabelLength('a'.repeat(SHARE_LABEL_MAX))).toBe(50);
    expect(labelLengthError('a'.repeat(SHARE_LABEL_MAX))).toBeNull();

    expect(shareLabelLength('a'.repeat(SHARE_LABEL_MAX + 1))).toBe(51);
    expect(labelLengthError('a'.repeat(SHARE_LABEL_MAX + 1))).toBe(MESSAGE);
  });

  it('accepts exactly the limit and refuses one unit more, in Japanese', () => {
    // Japanese is BMP: one code unit per character, so 50 units is 50 real
    // characters -- the count a user of this field would expect.
    expect(shareLabelLength('あ'.repeat(SHARE_LABEL_MAX))).toBe(50);
    expect(labelLengthError('あ'.repeat(SHARE_LABEL_MAX))).toBeNull();

    expect(labelLengthError('あ'.repeat(SHARE_LABEL_MAX + 1))).toBe(MESSAGE);
  });
});

describe('Unicode costs are counted in UTF-16 units, not glyphs', () => {
  it('charges a non-BMP emoji two units', () => {
    // 😀 is U+1F600: one code point, one glyph, two UTF-16 units.
    expect('😀'.length).toBe(2);
    expect(shareLabelLength('😀'.repeat(25))).toBe(50);
    expect(labelLengthError('😀'.repeat(25))).toBeNull();

    expect(labelLengthError('😀'.repeat(26))).toBe(MESSAGE);
  });

  it('charges a combining sequence per unit, so the same glyph has two prices', () => {
    const decomposed = 'か' + '゙'; // が as base + combining mark: 2 units
    expect(decomposed.length).toBe(2);
    expect(shareLabelLength(decomposed.repeat(25))).toBe(50);
    expect(labelLengthError(decomposed.repeat(25))).toBeNull();
    expect(labelLengthError(decomposed.repeat(26))).toBe(MESSAGE);

    // The precomposed character looks identical and costs half as much.
    expect(shareLabelLength('が'.repeat(25))).toBe(25);
  });

  it('refuses five ZWJ family emoji, which is five glyphs', () => {
    // 11 UTF-16 units each. This is the clearest case of the unit disagreeing
    // with the eye, and it is accepted: the policy is units, not graphemes.
    const family = '👨‍👩‍👧‍👦';
    expect(family.length).toBe(11);

    expect(shareLabelLength(family.repeat(4))).toBe(44);
    expect(labelLengthError(family.repeat(4))).toBeNull();

    expect(shareLabelLength(family.repeat(5))).toBe(55);
    expect(labelLengthError(family.repeat(5))).toBe(MESSAGE);
  });
});

describe('measurement is on the trimmed value', () => {
  it('does not charge for trailing whitespace at the boundary', () => {
    expect(shareLabelLength('a'.repeat(SHARE_LABEL_MAX) + '   ')).toBe(50);
    expect(labelLengthError('a'.repeat(SHARE_LABEL_MAX) + '   ')).toBeNull();
  });

  it('does not charge for leading whitespace at the boundary', () => {
    expect(shareLabelLength('   ' + 'a'.repeat(SHARE_LABEL_MAX))).toBe(50);
    expect(labelLengthError('   ' + 'a'.repeat(SHARE_LABEL_MAX))).toBeNull();
  });

  it('does not let surrounding whitespace rescue an over-long label', () => {
    expect(labelLengthError('  ' + 'a'.repeat(SHARE_LABEL_MAX + 1) + '  ')).toBe(MESSAGE);
  });

  it('counts interior whitespace, which is part of the label', () => {
    expect(shareLabelLength('取引先A用 10月')).toBe(9);
    expect(shareLabelLength('a b c')).toBe(5);
  });

  it('returns the label unchanged -- nothing here mutates or truncates', () => {
    const tooLong = 'a'.repeat(SHARE_LABEL_MAX + 10);
    labelLengthError(tooLong);
    shareLabelLength(tooLong);
    expect(tooLong).toHaveLength(SHARE_LABEL_MAX + 10);
  });
});

describe('the limit itself', () => {
  it('is the agreed value, which maxLength and the counter both read', () => {
    expect(SHARE_LABEL_MAX).toBe(50);
  });
});

describe('byte safety against the database CHECK', () => {
  /**
   * A UTF-16 code unit costs AT MOST 3 UTF-8 bytes:
   *
   *   U+0000-U+007F   1 byte  / 1 unit  = 1
   *   U+0080-U+07FF   2 bytes / 1 unit  = 2
   *   U+0800-U+FFFF   3 bytes / 1 unit  = 3   <- the ceiling; plain CJK is here
   *   U+10000+        4 bytes / 2 units = 2   (encoded as a surrogate pair)
   *
   * So Japanese text is simultaneously the field's primary input AND its
   * byte-worst case, and N units can never exceed 3N bytes. This is the whole
   * reason a UTF-16 product limit can guarantee anything about a byte CHECK --
   * a grapheme-cluster limit could not, since one cluster is unbounded in bytes.
   */
  it('cannot collide with share_links_label_len (octet_length <= 200)', () => {
    // If SHARE_LABEL_MAX is ever raised above 66, THIS is what fails: 67 * 3 is
    // 201, and a 67-character Japanese label would be refused by the database
    // with a raw 23514 after passing every client check.
    expect(SHARE_LABEL_MAX * 3).toBeLessThanOrEqual(200);
  });

  it('keeps every accepted worst case inside 150 bytes', () => {
    const encoder = new TextEncoder();
    // One entry per bytes-per-unit class, each at or near the limit.
    const accepted = [
      'a'.repeat(50), //                    1 byte/unit   ->  50
      'é'.repeat(50), //               2 bytes/unit  -> 100
      'あ'.repeat(50), //                   3 bytes/unit  -> 150 (the worst case)
      '�'.repeat(50), //               3 bytes/unit  -> 150 (upper BMP)
      '😀'.repeat(25), //                   4 bytes / 2 units -> 100
      ('か' + '゙').repeat(25), //      6 bytes / 2 units -> 150
      '👨‍👩‍👧‍👦'.repeat(4) + 'あ'.repeat(6), //   mixed, exactly 50 units
    ];

    for (const label of accepted) {
      expect(labelLengthError(label)).toBeNull();
      expect(label.length).toBeLessThanOrEqual(SHARE_LABEL_MAX);

      const bytes = encoder.encode(label).length;
      expect(bytes).toBeLessThanOrEqual(3 * label.length); // the ratio claim
      expect(bytes).toBeLessThanOrEqual(SHARE_LABEL_MAX * 3); // 150
      expect(bytes).toBeLessThan(200); // the database CHECK
    }
  });

  it('reaches exactly 150 bytes on the CJK worst case', () => {
    // Pinned so the headroom under 200 is a measured number, not a belief.
    expect(new TextEncoder().encode('あ'.repeat(SHARE_LABEL_MAX)).length).toBe(150);
  });
});
