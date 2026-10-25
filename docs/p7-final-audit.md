# P7 最終監査記録（2026-10-18・内部資料）

公開ユーザーガイド（日本語9章・英語9章）の公開可否を判定するための監査記録。
新機能は追加していない。本書は内部資料であり `content/` には置かない。

---

## 1. 監査対象

| 対象 | 範囲 |
| --- | --- |
| 本文 | `content/ja/*.md` 9章、`content/en/*.md` 9章（合計 約2,800行） |
| 画像 | `content/images/{ja,en}/` 17種類・34枚 |
| 生成 | `scripts/build-docs.mjs` → `src/generated/docs.ts` |
| 画面 | `src/features/docs/`、`src/routing/`、`.docs-*` CSS |
| 配信 | `scripts/guide-images.mjs`、`vercel.json` |

実装を正とし、推測で仕様を変更していない。本番環境へはアクセスしていない。

---

## 2. 検証方法

### 実装から事実を抽出して突き合わせた

ガイドの主張を人手で読むのではなく、実装から値を抽出して機械的に照合した。

| 事実 | 出典 | 値 |
| --- | --- | --- |
| `include_private` 既定 | `ShareDialog.tsx` `useState(true)` | **true** |
| `share_available` 既定 | `ShareDialog.tsx` `useState(false)` | false |
| ラベル上限 | `shareLinkLabel.ts` | 50 |
| 有効リンク上限 | `0016` | 25 |
| リンク総数上限 | `0016` | 200 |
| visibility | `0001` CHECK | private / busy_only / public |
| availability | `0020` CHECK | busy / available |
| 展開上限 | `0007` / `0009` | 5000 / 5000 |
| クライアント FREQ | `recurrence.ts` | DAILY / WEEKLY / MONTHLY |
| **SQL が展開できる FREQ** | `0006`/`0009`/`0010` | **DAILY / WEEKLY のみ** |
| 閲覧者のブロック表記 | 辞書 | ja 予定あり／空き時間、**en Busy／Open** |

ガイドの数値・既定値・用語はすべて一致した（不一致0件）。

### 引用されたUI文言を辞書と照合した

ガイドが引用符・引用ブロック・表の「表示 / Message」列で示す文言を抽出し、
辞書の値と文字単位で突き合わせた。**ここで7件の誤引用が見つかった**（§3）。

---

## 3. 発見した問題

### Important — 英語ガイドのUI文言の誤引用（7件・修正済み）

英語章が、メッセージを**実際の文言ではなく言い換え**で引用していた。意味は正しい
ため、見出し・表・リンクを比べる既存の構造テストでは検出できなかった。

引用は「読者が画面と突き合わせられる」という約束である。画面に無い語を探した
読者は、自分が違う場所を見ていると判断してしまう。

| 章 | ガイドの記述（誤） | 実際の文言 |
| --- | --- | --- |
| `recurring-events` | The number of individual changes to this repeating event has reached the limit | This repeating event has reached its limit for per-occurrence changes. Tidy those changes and try again |
| `share-links` | This link's settings could not be changed. It may have expired or been revoked. | This link’s setting could not be changed. It may be expired or revoked. The list has been refreshed. |
| `what-viewers-see` | (This screen does not mean there are no events.) | (this screen does not mean “no events”) |
| `faq` | The number of saved events has reached the limit | You have reached the limit for stored events |
| `faq` | The number of active share links has reached the limit | You have reached the limit for active share links |
| `faq` | The total number of share links has reached the limit | You have reached the limit for share links in total |
| `faq` | Creating links at once | Creating share links is temporarily limited |

**日本語9章は18/18 一致**。誤引用は英訳時に作り込まれたもので、日本語側には無い。

再発防止として `src/docs/quotedMessages.test.ts` を追加した。

> 補足: この検査の最初の版は**引用符のある箇所しか見ておらず**、変異テストで
> FAQの表の列（7件中3件の所在地）を素通しした。表の「表示 / Message」列も
> 対象に加えたところ、**7件目（Creating links at once）が新たに見つかった**。
> 検査を書いたら必ず壊して確かめること。

---

## 4. 正常に確認できた項目

### 内容

- visibility と availability の独立性（日英とも「2つの設定」「互いに影響しない」）
- `Busy` / `Available`（設定値）と `Open`（英語の閲覧者画面）の使い分け
- `share_available` が明示的オプトイン／隙間から推測しない（両方向の注意を維持）
- `include_private` 既定オン＋「後から変更できない」の明記
- Busy 優先と 14-17 / 15-16 の具体例（日英で同じ時間帯表）
- complete / indeterminate / not_requested の3値と、それぞれの意味の違い
- 匿名閲覧者に渡らないもの7項目（日英で同一）
- 繰り返しの対応範囲（毎年・序数曜日・日付指定は不可）と、**共有側で毎月が
  展開できない**という別問題の書き分け
- 所有者TZ（終日の暦日）と閲覧者TZ（時刻表示）の役割分担
- 言語設定と共有計算の独立性、ガイドの言語がURLで決まること

### 構造（9章すべて）

見出し数・見出しレベルの並び・表の数・表の行数・画像の数と順序・章間リンク数が
日英で**完全一致**。`sourceHash` は9/9が日本語本文のハッシュと一致。
画像17件すべてが `/content/images/en/`・manifest の英語 alt と文字列一致。

### 画面（iframe で実際のCSSビューポートを変更して測定）

| 幅 | 言語 | メディアクエリ | 横スクロール | はみ出し | h1先頭 | レベル飛び | 表 | 画像 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 360px | en | 発火 | なし | 0 | ✓ | 0 | 7/7 内部スクロール | 収まる |
| 414px | en | 発火 | なし | 0 | ✓ | 0 | 6/6 | 収まる |
| 768px | en | 発火 | なし | 0 | ✓ | 0 | スクロール不要 | 収まる |
| 1280px | en | 非発火 | なし | 0 | ✓ | 0 | スクロール不要 | 収まる |
| 360px | ja | 発火 | なし | 0 | ✓ | 0 | 収まる | 収まる |

英語で最長のサイドバー項目（`What people you share with see`）と最長の見出し
（`It says this repeating event has reached its limit for per-occurrence changes`）
はいずれも315pxで、360px幅に収まり折り返している。

### 操作

言語切替が章を維持、本文内リンク、断片アンカー、前後の章、戻る／進む、
いずれもURLと表示が同期。

### SEO・配信・セキュリティ

- 9章すべて自己canonical・`robots` なし・hreflang（ja / en / x-default→ja）
- 目次も両言語で indexable（全章翻訳により自動切替）
- 画像34枚が `image/png` でバイト単位一致
- `.md`・manifest・`docs/`・`scripts/`・`.env.local`・`package.json` すべて未配信
- 生成HTMLに危険なスキーム0件・イベントハンドラ属性0件・外部リンク0件
- 匿名で閲覧可能、Supabase通信0件（HTML・JS・CSS・画像のみ）

---

## 5. 未解決（Deferred）

| # | 項目 | 影響 |
| --- | --- | --- |
| D1 | **不明な章IDが HTTP 200** を返す（`vercel.json` の SPA rewrite） | `noindex` で検索結果には出ないが、ステータスとしては誤り |
| D2 | **OGP / Twitter カード未対応** | 共有時のプレビューが出ない |
| D3 | **sitemap.xml 未生成** | 18ページの発見がクロール任せ |
| D4 | **`VITE_PUBLIC_ORIGIN` 未設定** | 単一オリジンなら自己canonicalで正しい。複数ホスト配信時は要設定 |
| D5 | **メタデータがクライアント側更新** | JSを実行しないクローラには `index.html` の既定値しか見えない |
| D6 | **Vercel 実デプロイ未検証** | deploy 禁止のため |
| D7 | 英文のネイティブレビュー未実施 | 構造・用語は機械照合済み、読みやすさは未評価 |
| D8 | 実機（タッチ）未検証 | iframe はCSSビューポートを変えるだけ |

D5 は D1〜D3 と同じ根に由来する。解決するなら**ビルド時に章ごとの静的HTMLを
出力する**のが筋で、これは設計変更なので本監査では実装せず提案に留める。

---

## 6. 実施した修正

| ファイル | 内容 |
| --- | --- |
| `content/en/recurring-events.md` | 誤引用1件 |
| `content/en/share-links.md` | 誤引用1件 |
| `content/en/what-viewers-see.md` | 誤引用1件 |
| `content/en/faq.md` | 誤引用4件（表の列3件＋見出し1件） |
| `src/docs/quotedMessages.test.ts` | **新規**。引用文言の照合テスト |
| `src/generated/docs.ts` | 再生成 |

アプリ本体・CSS・ルーティング・SQL・辞書・画像・manifest は変更していない。
`sourceHash` に影響する日本語原文の変更も無い（英語本文のみの修正）。

---

## 7. 判定

**P7 は公開可能**と判断する。Blocker は0件。

Important 1件（誤引用7箇所）は本監査で修正済みで、再発防止テストを入れた。
Deferred 8件はいずれも公開を妨げず、D1〜D3・D5 は発見性と共有体験の改善、
D4・D6 は公開手順の確認事項である。
