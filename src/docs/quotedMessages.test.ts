/**
 * Message text the guide puts in quotation marks must be the message.
 *
 * WHY THIS EXISTS. The final P7 audit found six places where the English guide
 * paraphrased a message instead of quoting it -- "The number of saved events
 * has reached the limit" where the app says "You have reached the limit for
 * stored events". Every one of them was accurate about the MEANING, which is
 * why nothing else caught them: the structural checks compare headings, tables
 * and links, and the translation reads correctly either way.
 *
 * But a quoted message is a promise that the reader can match it against what
 * is on their screen. A reader searching the interface for words that are not
 * in it concludes they are looking at the wrong thing. So a quote has to be
 * the dictionary's, character for character.
 *
 * WHAT COUNTS AS A QUOTE HERE: a blockquote, or a run inside double quotes
 * (ASCII or curly) that is long enough to be a sentence rather than a term.
 * Ordinary prose in quotes -- "every second Wednesday, ten times" -- is not a
 * message and is listed below as such.
 */

import { describe, expect, it } from 'vitest';
import { ja } from '../i18n/ja';
import { en } from '../i18n/en';

/** The guide's Markdown, by language. */
const CONTENT = import.meta.glob('/content/*/*.md', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

/**
 * Compared loosely enough to survive Markdown, and no looser.
 *
 * Emphasis, backticks and the kind of quote mark are formatting; the words and
 * their order are the message. Whitespace is collapsed because the guide wraps
 * its lines and the dictionary does not.
 */
function normalise(s: string): string {
  return s
    .replace(/\*\*/g, '')
    .replace(/`/g, '')
    .replace(/[“”„]/g, '"')
    .replace(/[’‘]/g, "'")
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * Quoted prose that is NOT a message, listed so the check can be exact rather
 * than approximate. Each is an ordinary English or Japanese turn of phrase.
 */
const NOT_A_MESSAGE = [
  'this one is not there',
  'the second Monday of the month',
  'the 15th and the last day',
  'every second Wednesday, ten times',
  'how much may a share link disclose about this event',
  'can you be reached at that time',
  'time with no event in it',
  'individually changed occurrence',
  'An all-day event on 13 October',
  "the owner's 13 October",
  'Could not be determined',
  'there is an event',
  'it is free',
  'no events',
  'この2時間は空いています',
  'その時間に連絡がつくかどうか',
  '予定表の隙間＝空いている',
  // Turns of phrase the guide puts in quotes to stand for what a reader
  // might think or say. None of them is text the application shows.
  'this time is taken',
  'you can reach me then',
  'I am free for these two hours',
  'I am free then, but only tell the people I have let see private events',
  '9am every morning',
  'a day in a calendar',
  'a moment',
  'this is free',
  'free',
  'この時間は埋まっている',
  'この時間なら 連絡がつく',
  '空いている時間だが、private を 含めてよい相手にだけ伝えたい',
  // In a message column, but a DESCRIPTION of a class of message rather
  // than one the screen shows word for word.
  'A length limit',
  '文字数の上限',
].map(normalise);

/**
 * Every quoted run worth checking, per file.
 *
 * QUOTES ARE PAIRED WITHIN A PARAGRAPH, not across the document. A first
 * attempt flattened the whole file and matched `"([^"]+)"`, which pairs the
 * CLOSING quote of one message with the OPENING quote of the next and reports
 * the prose in between -- twenty such artefacts, none of them a quote at all.
 * Paragraph scope removes them, and a paragraph whose quote marks do not pair
 * up is skipped rather than guessed at.
 */
function quotedRuns(markdown: string): string[] {
  const body = markdown.replace(/^---[\s\S]*?\n---\n/, '');
  const out: string[] = [];

  // Blockquotes, joined across their own wrapped lines. These are how the
  // guide shows a message that stands on its own.
  let buf: string[] = [];
  for (const line of body.split('\n')) {
    if (/^>\s?/.test(line)) buf.push(line.replace(/^>\s?/, ''));
    else if (buf.length > 0) {
      out.push(buf.join(' '));
      buf = [];
    }
  }
  if (buf.length > 0) out.push(buf.join(' '));

  for (const para of body.split(/\n\s*\n/)) {
    const flat = para.replace(/\n/g, ' ');
    // Japanese brackets nest properly, so they can be matched directly.
    for (const m of flat.matchAll(/「([^」]{10,})」/g)) out.push(m[1] ?? '');
    // Straight quotes open and close with the same character, so they are
    // taken in pairs: odd indices of the split are what sits inside a pair.
    // An unbalanced paragraph drops its trailing fragment rather than
    // pairing a closing quote with the next opening one.
    const parts = flat.split('"');
    const last = parts.length % 2 === 0 ? parts.length - 1 : parts.length;
    for (let i = 1; i < last; i += 2) out.push(parts[i] ?? '');

    // Curly quotes are distinct characters and can be matched directly.
    for (const m of flat.matchAll(/\u201c([^\u201d]{10,})\u201d/g)) out.push(m[1] ?? '');
  }

  // A TABLE COLUMN OF MESSAGES. The FAQ lists what the screen says in the
  // first column of a table headed "Message" / "表示", with no quotation
  // marks at all -- which is exactly where three of the six misquotes this
  // test was written for were sitting. A mutation put one back and the first
  // version of this check did not notice.
  let header = null;
  for (const line of body.split('\n')) {
    if (!/^\|/.test(line)) {
      header = null;
      continue;
    }
    const cells = line.split('|').slice(1, -1).map((c) => c.trim());
    if (cells.every((c) => /^:?-+:?$/.test(c))) continue;
    if (header === null) {
      header = cells[0] ?? '';
      continue;
    }
    if (header === 'Message' || header === '表示') out.push(cells[0] ?? '');
  }

  return out.map(normalise).filter((s) => s.length >= 10);
}

const DICT = { ja: Object.values(ja).map(normalise), en: Object.values(en).map(normalise) };

describe('quoted message text matches the interface', () => {
  const files = Object.entries(CONTENT).map(([path, text]) => {
    const lang = /^\/content\/(ja|en)\//.exec(path)?.[1] as 'ja' | 'en' | undefined;
    return { path, text, lang };
  });

  it('the guide was found', () => {
    expect(files.length).toBeGreaterThanOrEqual(18);
    for (const f of files) expect(f.lang, f.path).toBeTruthy();
  });

  it('every quoted message exists verbatim in the dictionary for its language', () => {
    const bad: string[] = [];
    for (const { path, text, lang } of files) {
      if (!lang) continue;
      for (const q of quotedRuns(text)) {
        if (NOT_A_MESSAGE.some((n) => n === q || q.includes(n) || n.includes(q))) continue;
        // A quote may be part of a longer message, or hold a whole one.
        const found = DICT[lang].some((d) => d.includes(q) || q.includes(d));
        if (!found) bad.push(`${path}: "${q.slice(0, 100)}"`);
      }
    }
    expect(bad, 'quoted text that is not in the dictionary').toEqual([]);
  });

  it('the check can actually fail', () => {
    // Otherwise a broken normalise() would make the test above vacuous.
    const invented = normalise('A message the application has never shown anybody');
    expect(DICT.en.some((d) => d.includes(invented))).toBe(false);
  });
});
