import { afterAll, describe, expect, it } from 'vitest';
import { renderToStaticMarkup } from 'react-dom/server';
import { LanguageContext, type LanguageContextValue } from '../../i18n/LanguageProvider';
import type { Language } from '../../i18n/types';
import { checkWallTime } from './formInstant';
import { WallTimeNotice } from './WallTimeNotice';

/*
  The DST notice cannot be seen in this machine's browser (its zone has no
  DST), and the project runs vitest without jsdom. A static render needs
  neither: it shows exactly the markup the dialog would put under a timed
  field in a New York browser.
*/
const env = (globalThis as unknown as { process: { env: Record<string, string | undefined> } }).process.env;
const ORIGINAL_TZ = env.TZ;
afterAll(() => {
  if (ORIGINAL_TZ === undefined) delete env.TZ;
  else env.TZ = ORIGINAL_TZ;
});
const NY = 'America/New_York';

function render(lang: Language, local: string, choice: 'earlier' | 'later' | null = null): string {
  const ctx = { language: lang } as unknown as LanguageContextValue;
  return renderToStaticMarkup(
    <LanguageContext.Provider value={ctx}>
      <WallTimeNotice fieldLabel="開始" local={local} check={checkWallTime(local, NY)} choice={choice} onChoose={() => {}} name="t" />
    </LanguageContext.Provider>,
  );
}

describe('WallTimeNotice in a New York browser', () => {
  it('says nothing about a normal time', () => {
    env.TZ = NY;
    expect(render('ja', '2026-10-18T14:30')).toBe('');
  });

  it('a gap: explains, names the clock jump, offers no automatic fix', () => {
    env.TZ = NY;
    const html = render('ja', '2026-03-08T02:30');
    expect(html).toContain('role="alert"');
    expect(html).toContain('この時刻は存在しません');
    expect(html).toContain('2026-03-08 は 01:59 の次が 03:00 です');
    expect(html).toContain('60 分進みます');
    expect(html).not.toContain('type="radio"');
    expect(render('en', '2026-03-08T02:30')).toContain('On 2026-03-08, 01:59 is followed by 03:00');
  });

  it('a fold: two radios with offsets and abbreviations, the restored one checked', () => {
    env.TZ = NY;
    const html = render('ja', '2026-11-01T01:30', 'later');
    expect(html).toContain('この時刻は2回あります');
    expect(html).toContain('1回目 01:30 EDT (UTC−04:00)');
    expect(html).toContain('2回目 01:30 EST (UTC−05:00)');
    expect(html.match(/type="radio"/g)).toHaveLength(2);
    expect(html.match(/checked=""/g)).toHaveLength(1);
    expect(html.indexOf('checked=""')).toBeGreaterThan(html.indexOf('1回目'));
    const en = render('en', '2026-11-01T01:30', null);
    expect(en).toContain('1st 01:30 EDT (UTC−04:00)');
    expect(en).toContain('2nd 01:30 EST (UTC−05:00)');
    expect(en).not.toContain('checked');
  });
});
