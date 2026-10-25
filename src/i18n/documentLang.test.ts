import { describe, expect, it } from 'vitest';
import { syncDocumentLang } from './documentLang';

/*
  P8-finish-1: <html lang> follows the language the screen is in. index.html is
  served as lang="ja" and only the guide used to change it, so an English
  calendar, login page or share page was announced as Japanese. The DOM write
  is checked in the browser run; the rule and the wiring are pinned here.
*/

const code = (path: string) =>
  ((import.meta.glob('/src/**/*.{ts,tsx}', { query: '?raw', import: 'default', eager: true }) as Record<string, string>)[path] ?? '')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/.*$/gm, '$1');

describe('syncDocumentLang', () => {
  it('writes the language, both ways', () => {
    const doc = { documentElement: { lang: 'ja' } };
    syncDocumentLang(doc, 'en');
    expect(doc.documentElement.lang).toBe('en');
    syncDocumentLang(doc, 'ja');
    expect(doc.documentElement.lang).toBe('ja');
  });
  it('does nothing without a document (server render, tests)', () => {
    expect(() => syncDocumentLang(undefined, 'en')).not.toThrow();
  });
});

describe('wiring', () => {
  const provider = code('/src/i18n/LanguageProvider.tsx');
  const app = code('/src/App.tsx');

  it('the provider writes the language it RESOLVED, on mount and on every change, unless told not to', () => {
    expect(provider).toMatch(/useEffect\(\(\) => \{\s*if \(ownsDocumentLang\) syncDocumentLang\([^,]+, language\);\s*\}, \[ownsDocumentLang, language\]\);/);
    expect(provider).toMatch(/ownsDocumentLang = true,/);
  });

  it('the guide is the one route that keeps its own <html lang> (useDocMeta), and the others sync it', () => {
    const providers = [...app.matchAll(/<LanguageProvider([^>]*)>/g)].map((m) => m[1]!.trim());
    expect(providers).toEqual(['isPublicRoute', 'isPublicRoute ownsDocumentLang={false}', '']);
    expect(app).toMatch(/<LanguageProvider isPublicRoute ownsDocumentLang=\{false\}>\s*<DocsScreen/);
    expect(code('/src/features/docs/useDocMeta.ts')).toMatch(/document\.documentElement\.lang = lang;/);
  });

  it('the share page\'s provider is public: its language is the VIEWER\'s, never the owner\'s', () => {
    expect(app).toMatch(/<LanguageProvider isPublicRoute>\s*<div className="app">\s*<FreeBusyPage/);
  });
});
