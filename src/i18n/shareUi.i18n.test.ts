import { describe, expect, it } from 'vitest';
import { t } from './t';
import { ja } from './ja';
import { en } from './en';

/**
 * P3-b step 1 moved the SHARE UI's wording into the dictionary: the anonymous
 * page (FreeBusyPage) and the owner's link manager (ShareDialog).
 *
 * As in the earlier steps the claim is that NOTHING THE USER SEES CHANGED, so
 * the Japanese below is written out literally rather than read back from `ja`.
 * Reading it back would pass against any value, including a wrong one.
 *
 * These two files cannot be rendered here -- vitest runs `environment: 'node'`
 * and jsdom is deliberately not added -- so what is checked is the dictionary
 * the components now read, plus the structural guards in wiring.test.ts.
 */

const JP = /[ぁ-んァ-ヶ一-龯]/;

/** Keys under a prefix, read from the raw dictionary (no interpolation). */
const under = (prefix: string) =>
  (Object.keys(ja) as (keyof typeof ja)[]).filter((k) => String(k).startsWith(prefix));

describe('the anonymous page renders the same Japanese as before P3-b', () => {
  it('header, navigation and loading', () => {
    // P8-mobile-2 changed this one on purpose: the page shows busy time too.
    expect(ja['sharePage.subtitle']).toBe('予定の空き状況（読み取り専用）');
    expect(ja['sharePage.disabled']).toBe('共有機能は利用できません。');
    expect(ja['sharePage.thisWeek']).toBe('今週');
    expect(ja['sharePage.prevWeek']).toBe('前の週');
    expect(ja['sharePage.nextWeek']).toBe('次の週');
    expect(ja['sharePage.loading']).toBe('読み込み中…');
  });

  it('the completeness warning, word for word', () => {
    expect(ja['sharePage.incompleteWarning']).toBe(
      'この期間には未対応の繰り返し予定が含まれています。表示されていない時間も空いているとは限りません。',
    );
  });

  it('the four block labels, which are also their aria-labels', () => {
    expect(ja['sharePage.block.busyAllDay']).toBe('終日 予定あり');
    expect(ja['sharePage.block.busy']).toBe('予定あり');
    expect(ja['sharePage.block.availableAllDay']).toBe('終日 空き時間');
    expect(ja['sharePage.block.available']).toBe('空き時間');
  });

  it('both footers', () => {
    expect(ja['sharePage.footer.busyOnly']).toBe(
      '表示されるのは予定の有無（busy）のみで、内容は共有されません。',
    );
    expect(ja['sharePage.footer.withAvailable']).toBe(
      '表示されるのは予定の有無（busy）と、共有者が明示した空き時間（available）だけで、内容は共有されません。空き時間として表示されていない時間が空いているとは限りません。',
    );
  });
});

describe('the share dialog renders the same Japanese as before P3-b', () => {
  it('title, creation panel and copy button', () => {
    expect(ja['shareDialog.title']).toBe('空き時間を共有');
    expect(ja['shareDialog.created.title']).toBe('共有リンクを作成しました');
    expect(ja['shareDialog.created.copy']).toBe('コピー');
    expect(ja['shareDialog.created.copied']).toBe('コピー済');
  });

  it('the form', () => {
    expect(ja['shareDialog.label']).toBe('ラベル（任意・管理用）');
    expect(ja['shareDialog.labelPlaceholder']).toBe('例: 取引先A用');
    expect(ja['shareDialog.includePrivate']).toBe('非公開(private)の予定も busy として含める');
    expect(ja['shareDialog.shareAvailable']).toBe(
      '「空き時間(Available)」として登録した予定も公開する',
    );
    expect(ja['shareDialog.shareAvailableHint']).toBe(
      '公開されるのは、予定を「空き時間」として明示的に登録した時間だけです。予定が入っていない時間が自動的に空き時間として公開されることはありません。',
    );
    expect(ja['shareDialog.expiresAt']).toBe('有効期限（任意）');
    expect(ja['shareDialog.create']).toBe('リンクを作成');
    expect(ja['shareDialog.creating']).toBe('作成中…');
  });

  it('the list, its empty states and the three statuses', () => {
    expect(ja['shareDialog.list.title']).toBe('既存のリンク');
    expect(ja['shareDialog.list.revokedOnly']).toBe('失効済みのみ表示');
    expect(ja['shareDialog.list.empty']).toBe('リンクはまだありません。');
    expect(ja['shareDialog.list.noRevoked']).toBe('失効済みのリンクはありません。');
    expect(ja['shareDialog.list.noLabel']).toBe('(ラベルなし)');
    expect(ja['shareDialog.status.active']).toBe('有効');
    expect(ja['shareDialog.status.expired']).toBe('期限切れ');
    expect(ja['shareDialog.status.revoked']).toBe('失効済');
  });

  it('the per-row summary line', () => {
    expect(ja['shareDialog.sub.includePrivate']).toBe('private含む');
    expect(ja['shareDialog.sub.excludePrivate']).toBe('private除外');
    expect(ja['shareDialog.sub.availableShared']).toBe('空き時間を公開');
    expect(ja['shareDialog.sub.availableHidden']).toBe('空き時間は非公開');
  });

  it('the row controls and their refusal notices', () => {
    expect(ja['shareDialog.toggleAvailable']).toBe('空き時間(Available)を公開');
    expect(ja['shareDialog.toggleUpdating']).toBe('（更新中…）');
    expect(ja['shareDialog.expiredHint']).toBe(
      '期限切れですが失効していません。削除するには、先に「失効」してください。',
    );
    expect(ja['shareDialog.revoke']).toBe('失効');
    expect(ja['shareDialog.delete']).toBe('削除');
    expect(ja['shareDialog.deleteConfirm']).toBe('削除する');
    expect(ja['shareDialog.deleting']).toBe('削除中…');
    expect(ja['shareDialog.confirmDelete']).toBe(
      'このリンクの記録を完全に削除します。元に戻せません。',
    );
    expect(ja['shareDialog.deleteRefused']).toBe(
      'このリンクはすでに削除されたか、削除できない状態です。一覧を更新しました。',
    );
    expect(ja['shareDialog.availableRefused']).toBe(
      'このリンクの設定を変更できませんでした。期限切れか失効している可能性があります。一覧を更新しました。',
    );
  });

  it('the closing note about URLs being shown once', () => {
    expect(ja['shareDialog.note.urlOnce']).toBe(
      '既存リンクのURLは再表示できません（作成時のみ表示）。分からなくなった場合は失効して作り直してください。',
    );
  });

  it('reuses the shared buttons rather than redeclaring them', () => {
    // The dialog's cancel and close buttons were plain literals before; they
    // now come from `common.*`, which must still read the same.
    expect(ja['common.cancel']).toBe('キャンセル');
    expect(ja['common.close']).toBe('閉じる');
  });
});

/**
 * The three emphasised sentences.
 *
 * Each was one JSX paragraph with a <strong> in the middle. A single key would
 * have had to carry markup or lose the emphasis, so each is split into parts
 * that the component concatenates around the <strong>. The test is that the
 * parts REJOIN into the original sentence -- a split that reads correctly in
 * isolation but produces a broken sentence is the failure mode here.
 */
describe('the emphasised sentences survive being split', () => {
  it('the create warning rejoins', () => {
    const joined =
      ja['shareDialog.created.warnBefore'] +
      ja['shareDialog.created.warnEmphasis'] +
      ja['shareDialog.created.warnAfter'];
    expect(joined).toBe(
      'このURLは今だけ表示されます。閉じると再表示できません（トークンは保存されません）。必要なら今すぐコピーして共有先へ渡してください。',
    );
  });

  it('the emphasised word is the one that was emphasised', () => {
    // "only now" is the whole point of the warning; emphasising a different
    // span would still rejoin correctly and still be wrong.
    expect(ja['shareDialog.created.warnEmphasis']).toBe('今だけ');
    // "shown only now" was a literal rendering of 今だけ; "only once" says
    // the same thing in idiomatic English (P5 audit).
    expect(en['shareDialog.created.warnEmphasis']).toBe('only once');
  });

  it('the revoke and delete notes rejoin, each starting with its verb', () => {
    expect(ja['shareDialog.note.revokeTerm'] + ja['shareDialog.note.revokeBody']).toBe(
      '失効はURLを使えなくします。記録は残るため、総数の上限には数えられ続けます。',
    );
    expect(ja['shareDialog.note.deleteTerm'] + ja['shareDialog.note.deleteBody']).toBe(
      '削除は失効済みリンクの記録そのものを消し、総数の枠を空けます（元に戻せません）。',
    );
  });

  it('the English halves join without a missing or doubled space', () => {
    // English needs the space INSIDE the following part, because the component
    // emits the parts adjacently with no separator.
    for (const body of [
      en['shareDialog.created.warnAfter'],
      en['shareDialog.note.revokeBody'],
      en['shareDialog.note.deleteBody'],
    ]) {
      expect(body).not.toMatch(/^\s\s/);
    }

    // THE WHOLE PARAGRAPH, not just each term with its own body. The four
    // parts render adjacently, so the junction that matters most is the one
    // BETWEEN the two sentences -- and it was missed: English read
    // "...towards the total.Deleting removes..." until the trailing space was
    // added, because the newline separating them in the JSX is dropped.
    // Japanese is checked too, where the correct separator is none at all.
    const enParagraph =
      en['shareDialog.note.revokeTerm'] +
      en['shareDialog.note.revokeBody'] +
      en['shareDialog.note.deleteTerm'] +
      en['shareDialog.note.deleteBody'];
    expect(enParagraph).toBe(
      'Revoking stops the URL working. The record remains, so it still counts towards the total. ' +
        'Deleting removes the record of a revoked link and frees a slot (this cannot be undone).',
    );
    expect(enParagraph).not.toMatch(/\.[A-Z]/);

    const jaParagraph =
      ja['shareDialog.note.revokeTerm'] +
      ja['shareDialog.note.revokeBody'] +
      ja['shareDialog.note.deleteTerm'] +
      ja['shareDialog.note.deleteBody'];
    expect(jaParagraph).toContain('続けます。削除は');
    expect(jaParagraph).not.toMatch(/ /);
    expect(en['shareDialog.note.revokeTerm'] + en['shareDialog.note.revokeBody']).toBe(
      'Revoking stops the URL working. The record remains, so it still counts towards the total. ',
    );
    expect(en['shareDialog.note.deleteTerm'] + en['shareDialog.note.deleteBody']).toBe(
      'Deleting removes the record of a revoked link and frees a slot (this cannot be undone).',
    );
  });
});

/**
 * ONE RENDERED DIFFERENCE, RECORDED RATHER THAN HIDDEN.
 *
 * Before P3-b, two of these paragraphs were written across source lines inside
 * a single <p>. JSX collapses an interior newline plus indentation into one
 * space, so a space was rendered between the sentences. The parts are now
 * separate expressions, and JSX DROPS whitespace-only text that contains a
 * newline, so that space is gone.
 *
 * It is a whitespace-only change in Japanese running text, where the space was
 * an artifact of line wrapping rather than typography. It is asserted here so
 * that it is a known, deliberate difference and not something a later reader
 * discovers as a mystery.
 */
describe('the only rendered change is a dropped inter-sentence space', () => {
  it('the create warning no longer has the wrap-artifact space', () => {
    expect(ja['shareDialog.created.warnAfter']).toContain('保存されません）。必要なら');
    expect(ja['shareDialog.created.warnAfter']).not.toContain('保存されません）。 必要なら');
  });

  it('the revoke and delete notes are now two separate paragraphs of parts', () => {
    expect(ja['shareDialog.note.revokeBody'].endsWith('数えられ続けます。')).toBe(true);
    expect(ja['shareDialog.note.deleteTerm']).toBe('削除');
  });
});

describe('the one interpolated key', () => {
  it('puts the formatted expiry where the placeholder is', () => {
    expect(t('shareDialog.sub.expiresAt', 'ja', { at: '2026/1/2 10:00' })).toBe(
      '期限 2026/1/2 10:00',
    );
    expect(t('shareDialog.sub.expiresAt', 'en', { at: '2026/1/2 10:00' })).toBe(
      'expires 2026/1/2 10:00',
    );
  });

  it('does not hard-code a date format in either language', () => {
    // The value is produced by toLocaleString() in the component and travels
    // as a variable, so the dictionary must not try to format it.
    for (const s of [ja['shareDialog.sub.expiresAt'], en['shareDialog.sub.expiresAt']]) {
      expect(s).toMatch(/\{at\}/);
      expect(s).not.toMatch(/\d/);
    }
  });
});

describe('the English share UI is complete and clean', () => {
  it('every share key has a non-empty English value with no Japanese left in it', () => {
    const keys = [...under('sharePage.'), ...under('shareDialog.'), ...under('legend.')];
    // Guards against the list silently shrinking to nothing.
    expect(keys.length).toBeGreaterThan(50);
    for (const k of keys) {
      const s: string = en[k];
      expect(s.trim(), String(k)).not.toBe('');
      expect(s, String(k)).not.toMatch(JP);
    }
  });

  it('no English share string leaks an uninterpolated placeholder', () => {
    // Placeholder PARITY is a compile-time check in dictionaries.ts. This is
    // the other half: a key with no variables must contain no braces at all.
    const keys = [...under('sharePage.'), ...under('shareDialog.'), ...under('legend.')];
    for (const k of keys) {
      if (/\{\w+\}/.test(ja[k])) continue; // intentionally interpolated
      expect(en[k], String(k)).not.toMatch(/\{\w+\}/);
    }
  });
});

/**
 * THE SAFETY MEANINGS OF THE SHARE UI.
 *
 * This screen is read by people who have no account and no other source of
 * truth about the owner's calendar, so the wording is load-bearing. Each
 * assertion below pins a distinction that a fluent rewrite would erase, in
 * BOTH languages -- the English is new and therefore unproven.
 */
describe('busy and available stay distinguishable', () => {
  it('the busy and available block labels are never the same string', () => {
    for (const d of [ja, en]) {
      expect(d['sharePage.block.busy']).not.toBe(d['sharePage.block.available']);
      expect(d['sharePage.block.busyAllDay']).not.toBe(d['sharePage.block.availableAllDay']);
    }
  });

  it('the busy label does not use the word for open time', () => {
    expect(ja['sharePage.block.busy']).not.toContain('空き');
    expect(en['sharePage.block.busy']).not.toMatch(/open|available|free/i);
  });

  it('the available label does not read as "a scheduled event"', () => {
    expect(ja['sharePage.block.available']).not.toContain('予定あり');
    expect(en['sharePage.block.available']).not.toMatch(/busy/i);
  });
});

describe('what is NOT shown is never presented as free', () => {
  it('the available footer keeps the caveat', () => {
    expect(ja['sharePage.footer.withAvailable']).toContain('空いているとは限りません');
    expect(en['sharePage.footer.withAvailable']).toMatch(/not necessarily free/i);
  });

  it('the incomplete warning keeps the caveat', () => {
    expect(ja['sharePage.incompleteWarning']).toContain('空いているとは限りません');
    expect(en['sharePage.incompleteWarning']).toMatch(/not necessarily free/i);
  });

  it('both footers say the CONTENTS are not shared', () => {
    expect(ja['sharePage.footer.busyOnly']).toContain('内容は共有されません');
    expect(ja['sharePage.footer.withAvailable']).toContain('内容は共有されません');
    expect(en['sharePage.footer.busyOnly']).toMatch(/contents are not shared/i);
    expect(en['sharePage.footer.withAvailable']).toMatch(/contents are not shared/i);
  });

  it('the busy-only footer does not mention open time at all', () => {
    // It is shown for links that did not opt in. Naming available time there
    // would imply a question was asked and answered.
    expect(ja['sharePage.footer.busyOnly']).not.toContain('空き時間');
    expect(en['sharePage.footer.busyOnly']).not.toMatch(/\bopen\b|available/i);
  });
});

describe('the sharing-disabled line discloses nothing', () => {
  it('names no reason and makes no claim about the calendar', () => {
    expect(en['sharePage.disabled']).not.toMatch(
      /expired|revoked|deleted|unknown|invalid|not found|free|busy/i,
    );
    expect(ja['sharePage.disabled']).not.toContain('空い');
  });
});

describe('the opt-in hint promises that gaps are never published', () => {
  it('Japanese keeps both halves: explicit only, and never automatic', () => {
    expect(ja['shareDialog.shareAvailableHint']).toContain('明示的');
    expect(ja['shareDialog.shareAvailableHint']).toContain('自動的に');
    expect(ja['shareDialog.shareAvailableHint']).toContain('ことはありません');
  });

  it('English keeps both halves', () => {
    const s = en['shareDialog.shareAvailableHint'];
    expect(s).toMatch(/explicitly|marked/i);
    expect(s).toMatch(/never/i);
    expect(s).toMatch(/automatically/i);
  });
});

describe('include-private and share-available are two different switches', () => {
  it('their labels are distinct and each names its own subject', () => {
    for (const d of [ja, en]) {
      expect(d['shareDialog.includePrivate']).not.toBe(d['shareDialog.shareAvailable']);
    }
    expect(en['shareDialog.includePrivate']).toMatch(/private/i);
    expect(en['shareDialog.includePrivate']).toMatch(/busy/i);
    // The available switch is additive disclosure, not a privacy setting.
    expect(en['shareDialog.shareAvailable']).not.toMatch(/private/i);
    expect(en['shareDialog.shareAvailable']).toMatch(/open|available/i);
  });

  it('the per-row summary keeps the four states apart', () => {
    for (const d of [ja, en]) {
      const four = [
        d['shareDialog.sub.includePrivate'],
        d['shareDialog.sub.excludePrivate'],
        d['shareDialog.sub.availableShared'],
        d['shareDialog.sub.availableHidden'],
      ];
      expect(new Set(four).size).toBe(4);
    }
  });
});

describe('revoke and delete are never interchangeable', () => {
  it('the two verbs are different words in both languages', () => {
    for (const d of [ja, en]) {
      expect(d['shareDialog.revoke']).not.toBe(d['shareDialog.delete']);
      expect(d['shareDialog.note.revokeTerm']).not.toBe(d['shareDialog.note.deleteTerm']);
    }
  });

  it('revoking is described as leaving the record and the quota', () => {
    expect(ja['shareDialog.note.revokeBody']).toContain('記録は残る');
    expect(ja['shareDialog.note.revokeBody']).toContain('総数');
    const s = en['shareDialog.note.revokeBody'];
    expect(s).toMatch(/record remains/i);
    expect(s).toMatch(/total/i);
  });

  it('deleting is described as freeing a slot and being irreversible', () => {
    expect(ja['shareDialog.note.deleteBody']).toContain('枠を空けます');
    expect(ja['shareDialog.note.deleteBody']).toContain('元に戻せません');
    const s = en['shareDialog.note.deleteBody'];
    expect(s).toMatch(/frees a slot/i);
    expect(s).toMatch(/cannot be undone/i);
  });

  it('the expired-but-not-revoked hint still tells the owner to revoke first', () => {
    // 0015 refuses to delete a row that is not revoked, so this hint is the
    // only thing standing between the owner and a button that does nothing.
    expect(en['shareDialog.expiredHint']).toMatch(/revoke it first/i);
  });

  it('the delete confirmation says it is permanent', () => {
    expect(en['shareDialog.confirmDelete']).toMatch(/permanently/i);
    expect(en['shareDialog.confirmDelete']).toMatch(/cannot be undone/i);
  });

  it('the three statuses are three distinct words', () => {
    for (const d of [ja, en]) {
      const three = [
        d['shareDialog.status.active'],
        d['shareDialog.status.expired'],
        d['shareDialog.status.revoked'],
      ];
      expect(new Set(three).size).toBe(3);
    }
  });
});

describe('the token is still described as unrecoverable', () => {
  it('the create warning says it cannot be shown again', () => {
    expect(en['shareDialog.created.warnAfter']).toMatch(/cannot be shown again/i);
    expect(en['shareDialog.created.warnAfter']).toMatch(/not stored/i);
  });

  it('the list note repeats it for existing links', () => {
    expect(en['shareDialog.note.urlOnce']).toMatch(/cannot be shown again/i);
    expect(ja['shareDialog.note.urlOnce']).toContain('再表示できません');
  });
});

/**
 * THE LEGEND KEYS, WHICH NO UI READS YET.
 *
 * Prepared now so the wording is reviewed with the rest of the share copy, and
 * guarded now for the same reason. The visual contract is NOT hue -- busy is a
 * filled bar, available is the page surface inside an outline plus a 45-degree
 * hatch -- so a legend that said "the blue blocks" would be wrong on paper, in
 * greyscale, and for anyone who cannot distinguish the two colours.
 */
describe('the legend keys exist and are safe to ship', () => {
  it('all four are present in both languages', () => {
    for (const k of ['legend.title', 'legend.busy', 'legend.available', 'legend.note', 'legend.noteBusyOnly'] as const) {
      expect(ja[k].trim()).not.toBe('');
      expect(en[k].trim()).not.toBe('');
    }
  });

  it('no legend string names a colour', () => {
    // Checked as WORDS, not substrings: "shared" contains "red", and every
    // one of these strings is entitled to say the contents are not shared.
    const COLOUR_WORDS = ['color', 'colour', 'colors', 'colours', 'blue', 'green', 'red', 'grey', 'gray', 'shaded', 'shading'];
    for (const k of ['legend.title', 'legend.busy', 'legend.available', 'legend.note', 'legend.noteBusyOnly'] as const) {
      const words = en[k].toLowerCase().split(/[^a-z]+/);
      for (const w of COLOUR_WORDS) expect(words, k).not.toContain(w);
      expect(ja[k], k).not.toMatch(/色|青|緑|赤|灰色|グレー/);
    }
  });

  it('available is described as time the owner MARKED, not as time with no events', () => {
    expect(ja['legend.available']).toContain('登録した');
    expect(ja['legend.available']).not.toContain('予定がない');
    expect(ja['legend.available']).not.toContain('予定のない');
    const s = en['legend.available'];
    expect(s).toMatch(/marked/i);
    expect(s).not.toMatch(/no events|not busy|gap/i);
  });

  it('busy still says the contents are not shared', () => {
    expect(ja['legend.busy']).toContain('内容は共有されません');
    expect(en['legend.busy']).toMatch(/contents are not shared/i);
  });

  it('the legend carries the same caveat as the footer', () => {
    expect(ja['legend.note']).toContain('空いているとは限りません');
    expect(en['legend.note']).toMatch(/not necessarily free/i);
    expect(ja['legend.noteBusyOnly']).toContain('空いているとは限りません');
    expect(en['legend.noteBusyOnly']).toMatch(/not necessarily free/i);
  });

  it('the share page and its legend module read them, and nothing else does (P8-mobile-2)', () => {
    const MODULES = import.meta.glob('/src/**/*.{ts,tsx}', {
      query: '?raw',
      import: 'default',
      eager: true,
    }) as Record<string, string>;
    const readers = Object.entries(MODULES)
      .filter(([p]) => !p.includes('.test.'))
      .filter(([, text]) => /'legend\./.test(text))
      .map(([p]) => p.replace(/^\/src\//, ''));
    // The dictionaries declare them; the anonymous page and freeBusyLegend.ts
    // (which decides which entries are shown) read them.
    expect(readers.sort()).toEqual(['features/share/FreeBusyPage.tsx', 'features/share/freeBusyLegend.ts', 'i18n/en.ts', 'i18n/ja.ts']);
  });
});
