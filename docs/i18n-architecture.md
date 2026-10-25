# i18n アーキテクチャ設計書（調査結果と推奨設計）

**状態: 調査・設計のみ。実装は未着手。**

対象は現在のアプリUIと、将来追加するヘルプ・利用ガイド・FAQ・仕様ドキュメント。

---

## 1. 既存実装の調査結果（すべて実測）

### 1-1. 日本語文字列の分布

非テストの **31ファイル・196行**に日本語が含まれる。重要なのは総数ではなく**どこにあるか**で、
この分布が実装計画の順序をそのまま決める。

**A. 既に純粋モジュールに集約済み（＝移行が容易・先にやるべき）**

| ファイル | 行 | 内容 |
|---|---|---|
| `errors.ts` | 18 | ドメインエラー文言（11クラス） |
| `features/settings/timezoneSetting.ts` | 10 | タイムゾーン/言語の注記 |
| `features/calendar/eventTitle.ts` | 4 | 無題・空き時間のフォールバック |
| `features/calendar/visibilityMeta.ts` | 3 | 公開範囲ラベル |
| `services/contentLimits.ts` | 3 | 長さ超過メッセージ |
| `features/event/recurrenceForm.ts` | 3 | 繰り返しラベル |
| `features/share/availablePresentation.ts` | 2 | Available の2文 |
| `features/share/freeBusyPresentation.ts` | 2 | unavailable / 空期間の2文 |
| `features/share/freeBusyBanner.ts` | 2 | 取得失敗バナー |
| `features/calendar/weekGrid.ts` / `monthGrid.ts` / `dayAgenda.ts` / `shareLinkLabel.ts` | 各1-2 | 見出し・単位 |

**この集約は偶然ではない。** 本プロジェクトは vitest を `environment: 'node'` で動かし
**jsdom を追加しない**方針のため、「JSX に直書きした判断はテストできない」という理由で
文言を純粋モジュールへ追い出してきた。`freeBusyPresentation.ts` のヘッダに
「この copy はテストが何を言い/言わないかを検証できるようここに置く」と明記されている。
**i18n はこの既存方針の延長であって、新しいパラダイムの導入ではない。**

**B. コンポーネントに直書き（移行の本体）**

```
ShareDialog.tsx      36    EventDialog.tsx     34
FreeBusyPage.tsx     15    RecurrenceEditor.tsx 15
SettingsDialog.tsx   12    CalendarToolbar.tsx   6
DayAgendaDialog.tsx   4    CalendarPage.tsx      3
MonthView.tsx         3    App.tsx               3
AllDayLane.tsx        2    TimeGridView.tsx      2
LoginPage.tsx         2    AuthGate.tsx          1
```

### 1-2. 日付・時刻・曜日・タイムゾーン

**配管は半分できている。** 以下は既に `locale?` 引数を受ける。

```
utils/datetime.ts:125   formatTime(iso, locale?)
utils/datetime.ts:129   （日付整形）
features/calendar/monthGrid.ts:48   monthTitle(anchor, locale?)
features/calendar/weekGrid.ts:71    formatDayKey(dayKey, opts, locale?)
```

ただし**呼び出し側が誰も渡していない**ため、実行時はブラウザ既定ロケールになる。
i18n はこの引数に解決済み言語を流すだけで済む。

ロケールを渡していない箇所が2つある（要対応）。

```
features/calendar/DayAgendaDialog.tsx:34   toLocaleDateString(undefined, {...})
features/share/ShareDialog.tsx:378         new Date(l.expiresAt).toLocaleString()
```

**曜日ラベルは4箇所にハードコード。**

```
MonthView.tsx:25        ['月','火','水','木','金','土','日']
TimeGridView.tsx:14     同上
FreeBusyPage.tsx:54     同上
RecurrenceEditor.tsx:33 Record<Weekday, string>（MO..SU → 月..日）
```

> **★ 触ってはいけない1行**
> `utils/timezone.ts:98` の `new Intl.DateTimeFormat('en-US', { timeZone: tz })` は
> **タイムゾーン名の妥当性検査**であって表示ではない。ここを解決済み言語にすると
> 検査の意味が変わる。i18n の対象外として固定すること。

### 1-3. `owner_settings.language` の読み書き

```
読み  repositories/ownerSettingsRepository.ts  getOwnerSettings()
      未知の値（'fr' 等）は null に倒す＝「ブラウザに従う」
書き  saveOwnerSettings()  upsert、CHECK で ja|en|null のみ
UI    features/settings/SettingsDialog.tsx
```

**現在この値は誰も読んでいない。** 設定画面が保存するだけで、画面には一切反映されない。
設定画面自身がその事実を明記している（`LANGUAGE_PENDING_NOTICE`）。

**SQL からも読まれない。** 0025 postflight の H02 が helper 本文の `language` 参照を
0件に固定している。表示言語が Free/Busy 計算に混入しないことは構造的に保証済み。

### 1-4. ブラウザ言語の取得

```
navigator.language / navigator.languages の使用箇所: 0
```

**i18n の入口そのものが存在しない。** 新規に作る必要がある。

### 1-5. ルーティング

```
src/App.tsx:13   /^\/s\/([^/]+)\/?$/  ← これが唯一のルート判定
react-router 等のルータ: 未導入
```

匿名共有だけが別ルートで、それ以外は単一画面。
**ドキュメントの `/ja/docs/...` を足すには最小限のルート判定追加が要る**が、
ルータライブラリの導入は現時点では不要（§3-2）。

### 1-6. 依存パッケージ

```
runtime : @supabase/supabase-js, date-fns, date-fns-tz, react, react-dom   （5つだけ）
dev     : @types/react, @types/react-dom, @vitejs/plugin-react, typescript, vite, vitest
i18n 系 : なし
```

### 1-7. 既存テストへの影響

```
日本語を含むテストファイル        29件
日本語リテラルを直接アサート      61箇所 / 11ファイル
```

内訳（アサート数）:

```
timezoneSetting.test.ts 13   shareLinkError.test.ts 7   freeBusyError.test.ts 7
freeBusyBanner.test.ts   7   eventWriteError.test.ts 7  contentLimits.test.ts  6
availablePresentation    4   freeBusyPresentation    4  eventTitle.test.ts     4
eventMapping / eventRepository  各1
```

**この61箇所が移行コストの実体。** ただし大半は「文言が何を言い、何を言わないか」を
検証するテストで、i18n 後は `t('key', 'ja')` を介して同じことを検証できる。
テストを削除・弱体化して通す方法は採らない。

---

## 2. 共通 i18n アーキテクチャ

### 2-1. ライブラリ選定 — **軽量な独自実装を推奨**

| | i18next + react-i18next | 独自実装（推奨） |
|---|---|---|
| 追加依存 | 2〜3パッケージ・約40KB | **0** |
| 型安全 | module augmentation か codegen が必要 | `as const` + `keyof` で**標準機能のみ**で完全 |
| テスト | React hook/context 前提。**jsdom が無いこの環境では UI 層をテストできない** | 純粋関数 `t(key, lang)`。node 環境でそのままテスト可能 |
| 既存方針との整合 | 新しいパラダイム | **既存の「純粋モジュールが copy を持つ」方針の延長** |
| 複数形・ICU | あり | ja に複数形は無く、en も現状の文言には不要 |
| 遅延ロード | あり | 200文字列では不要。ドキュメント側で別途必要（§3） |

**判断の決め手は3つ。**

1. **テスト可能性。** この環境は `environment: 'node'` で jsdom を**追加しない**方針。
   i18next の価値の大半は React 統合にあるが、その層をここではテストできない。
   逆に `t(key, lang)` は純粋関数なので、既存の61アサートをそのまま置き換えられる。
2. **依存の少なさ。** 実行時依存は5つしかない。CLS 対策やバンドル重量に配慮してきた
   プロジェクトで、200文字列のために40KBを足す合理性が無い。
3. **既存コードがほぼ i18n 可能な形になっている。** 文言は純粋モジュールに集約済みで、
   日付整形は `locale?` を受ける。独自実装なら**この形をそのまま辞書に移すだけ**で済む。

> **再評価の条件を明記しておく。** ドキュメントのページ数が増え、
> 名前空間の遅延ロード・複数形・性別/文脈分岐が必要になったら i18next を再検討する。
> 独自実装は `t()` という1関数の裏に閉じるので、その時点での差し替えコストは小さい。

### 2-2. 言語解決 — UIとドキュメントで共通の純粋関数

```ts
// src/i18n/resolveLanguage.ts
export type Language = 'ja' | 'en';

export function resolveLanguage(input: {
  stored: Language | null;           // owner_settings.language（匿名は常に null）
  browser: readonly string[];        // navigator.languages
}): Language
```

```
stored が 'ja' | 'en'      → それを使う（明示設定が最優先）
stored が null             → browser を先頭から走査し、最初に ja*/en* に一致したもの
一致なし・browser が空      → 'ja'（フォールバック）
```

**匿名閲覧者は stored を持たない**ので、必ずブラウザ言語になる。これは
タイムゾーンと**逆**であることを強調しておく（下表）。両者を取り違えると、
0025 で退けたのと同種の誤りになる。

| | タイムゾーン | 表示言語 |
|---|---|---|
| 誰のものか | **オーナー** | **見ている人** |
| 匿名ページでの出どころ | オーナーの保存値 | 閲覧者のブラウザ |
| SQL が読むか | **読む** | **読まない**（0025 H02 が参照0件を固定） |
| 未設定時 | クロスモデルのみ fail-closed | `ja` にフォールバック |

### 2-3. 辞書と型安全

```ts
// src/i18n/ja.ts
export const ja = {
  'common.save':            '保存',
  'common.cancel':          'キャンセル',
  'share.available.optIn':  '「空き時間(Available)」として登録した予定も公開する',
  'event.titleRequired':    'タイトルを入力してください',
  // …
} as const;

// src/i18n/types.ts
export type MessageKey = keyof typeof ja;

// src/i18n/en.ts
import type { MessageKey } from './types';
export const en: Record<MessageKey, string> = { /* … */ };
//            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ キー欠落はコンパイルエラー
```

**`ja` が鍵集合の定義そのもの**であり、`en` は `Record<MessageKey, string>` なので
**翻訳漏れは tsc が落とす**。コード生成も module augmentation も要らない。

補間は最小限の実装に留める。

```ts
t('share.labelCount', { n: 12, max: 50 })   // '{n} / {max}'
```

### 2-4. 未使用キーと未翻訳の検出

```
翻訳漏れ   tsc（Record<MessageKey, string> が欠落を落とす）
未使用キー テストで src を走査し t('…') の実引数集合と辞書キー集合を比較
同一文言   ja と en が同一文字列のキーを列挙（翻訳忘れの疑いとして報告）
禁止事項   「JSX に日本語リテラルが残っていないこと」を移行済みディレクトリ単位で検査
```

いずれも**純粋なファイル走査**なので jsdom 不要。`src/i18n/coverage.test.ts` 1本に収める。

### 2-5. 日付・時刻のローカライズ

既存の `locale?` 引数に解決済み言語を流す。渡していない2箇所を同じ形に揃える。

```
Language → BCP47     ja → 'ja-JP'   en → 'en-US'
曜日ラベル            Intl.DateTimeFormat(locale, { weekday:'short' }) から導出し、
                      4箇所のハードコード配列を1つの純粋関数に統合
```

> **週の開始は月曜固定のまま変える。** `weekStartDayKey` が月曜起点で、
> 0024/0025 の窓生成がこれに依存している。ロケールで日曜起点に変えると
> **匿名共有の窓が変わる**＝Free/Busy の計算結果が変わる。i18n の対象外とする。

### 2-6. 変更しないもの（明示）

```
Free/Busy の計算        言語は SQL に到達しない（0025 H02）
権限・RLS               無関係
匿名共有の開示条件       include_private / share_available / owner タイムゾーンのみで決まる
週の開始曜日             月曜固定（窓生成が依存）
utils/timezone.ts:98    'en-US' 固定（表示ではなく検査）
```

---

## 3. 将来のドキュメント対応

**今回は実装しない。** 後から大幅な再設計が不要になる構造だけを決める。

### 3-1. コンテンツの置き方

```
docs/content/
  ja/getting-started.md
  ja/share-links.md
  en/getting-started.md
  en/share-links.md
```

**ページIDは言語に依存しない**（`getting-started`）。ディレクトリだけが言語。
これにより言語切替は「同じIDの別ディレクトリへ移る」だけになる。

front-matter で翻訳の鮮度を管理する。

```yaml
---
id: getting-started
title: はじめに
sourceHash: a1b2c3d4        # ja 版本文の hash。en 側に持たせる
---
```

**翻訳の更新漏れ検出**: ja を編集すると hash が変わり、en の `sourceHash` と食い違う。
CI（またはテスト）でこの不一致を列挙する。0025 の指紋ゲートと同じ考え方。

**Markdown を推奨し、MDX は採らない。** MDX は React コンポーネントを埋められる反面、
コンテンツがビルドと結合し、翻訳者がコードを触ることになる。
将来インタラクティブな図が必要になった時点で、該当ページだけ MDX に切り替えればよい。

### 3-2. URL 構造とルーティング

```
/ja/docs/getting-started
/en/docs/getting-started
/docs/getting-started        → 解決済み言語へ 302 相当のクライアント遷移
```

現在のルート判定は `App.tsx` の正規表現1本。**ルータライブラリは導入しない。**
判定を1つの純粋関数に切り出す。

```ts
// src/routing/route.ts
export type Route =
  | { kind: 'share'; token: string }
  | { kind: 'docs'; lang: Language | null; pageId: string }
  | { kind: 'app' };

export function parseRoute(pathname: string): Route
```

純粋関数なので node でテストできる。react-router は、ページ数が増えて
ネスト・遅延ロードが要るようになってから再検討する。

### 3-3. 未翻訳ページ・リンク・検索・SEO

```
未翻訳ページ     ja へフォールバックし、「この言語版はまだありません」を明示。
                 404 にはしない（情報に到達できないのが最悪）
言語切替         同じ pageId の別言語へ。存在しなければ一覧へ戻し、理由を表示
ドキュメント内リンク  相対リンクを現在の言語プレフィックス付きに解決する1関数を通す。
                 生の <a href> を書かせない
検索             本文を言語別インデックスに分けられるよう、front-matter に lang を持たせる。
                 実装は将来。構造だけ用意する
バージョン管理    content/ を git 管理下に置き、ページの履歴 = git 履歴とする。
                 専用のバージョン機構は作らない
静的生成・SEO     各言語ページに hreflang と canonical を出せるよう、
                 pageId + lang からURLを生成する関数を1つに集約しておく
```

---

## 4. 現在の暫定状態からの移行

**いま起きていること**: 設定画面は言語を保存するが、翻訳層が無いため画面は常に日本語。
設定画面はその事実を明記している（`LANGUAGE_PENDING_NOTICE`）。

**この注記をいつ外すかが移行の完了条件**であり、早く外すと「English を選んだのに
日本語のまま」という最悪の体験になる。詳細な段階分けは
`docs/i18n-implementation-plan.md` に記す。

---

## 5. まとめ

```
ライブラリ    独自実装（約100行）。i18next は採らない
              決め手はテスト可能性・依存の少なさ・既存方針との整合
言語解決      resolveLanguage({stored, browser}) の純粋関数。UIとドキュメントで共通
型安全        ja を as const で定義し en を Record<keyof typeof ja, string> に。
              翻訳漏れは tsc が落とす
検出          未使用キー・同一文言・JSX 残存リテラルをテスト1本で走査
日付          既存の locale? 引数に流す。曜日4箇所を1関数へ集約
ドキュメント  docs/content/{ja,en}/<id>.md、言語非依存ID、sourceHash で更新漏れ検出。
              ルータは入れず parseRoute の純粋関数で対応
不変          Free/Busy 計算・権限・開示条件・週開始曜日・ゾーン検査の 'en-US'
```
