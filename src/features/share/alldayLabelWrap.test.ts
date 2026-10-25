import { describe, expect, it } from 'vitest';

/*
  K11 (P8-finish-3a). On the share page the all-day label 「終日 予定あり」 is plain
  text in a flex box, and Japanese may break between any two characters: at
  641-748px a 7-column day read 「終日 予定あ／り」. The fix is two declarations on
  the all-day block only. The rendered result (no break inside a word, no
  overflow, 320-1280px, ja/en, light/dark) is checked in the browser run; this
  pins the rule and its scope.
*/

// Read from disk: Vitest hands CSS modules to tests as '' (even with ?raw),
// and the project carries no Node typings, hence the narrow local type.
type NodeFs = { readFileSync(path: string, encoding: 'utf8'): string };
const nodeProcess = (globalThis as unknown as {
  process: { cwd(): string; getBuiltinModule(id: 'node:fs'): NodeFs };
}).process;
const css = nodeProcess
  .getBuiltinModule('node:fs')
  .readFileSync(`${nodeProcess.cwd()}/src/styles/global.css`, 'utf8')
  .replace(/\/\*[\s\S]*?\*\//g, '');

it('the stylesheet was actually read', () => {
  expect(css).toMatch(/\.freebusy-block\s*\{/);
});

const blocks = (selector: string) =>
  [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].filter((m) => m[1]!.trim() === selector).map((m) => m[2]!);

describe('K11: the all-day label breaks only between words', () => {
  it('the all-day block keeps words together and can still never overflow', () => {
    const body = blocks('.freebusy-block.allday').join(';');
    expect(body).toMatch(/word-break:\s*keep-all/);
    expect(body).toMatch(/overflow-wrap:\s*anywhere/);
  });

  it('the rule is scoped to that block: no other selector gains keep-all', () => {
    const withKeepAll = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)]
      .filter((m) => /word-break:\s*keep-all/.test(m[2]!))
      .map((m) => m[1]!.trim());
    expect(withKeepAll).toEqual(['.freebusy-block.allday']);
  });
});
