# P7-d スクリーンショット撮影手順書（内部資料）

本書は**内部資料**であり、`content/` には置かない。公開されない。

**何を撮るか**は `docs/p7-screenshot-plan.md`（撮影計画）にある。本書は**どう撮るか**
だけを扱う。別のセッション・別のマシンでも同じ画像を撮り直せることが目的である。

---

## 1. 必要なもの

| | |
| --- | --- |
| モックAPI | `scripts/mock-supabase.mjs`（リポジトリ内） |
| 環境変数 | `.env.mockapi`（リポジトリ直下。未追跡） |
| ブラウザ | 実ブラウザ。画像生成AIで画面を再現したものは**使わない** |

本番Supabase・実ユーザー・実トークン・実予定には**一切アクセスしない**。
モックは本番へ接続する経路を持たない。

> **第1段階（6枚撮影時）はモックAPIがセッション用の一時ディレクトリにあった。**
> それでは「後から別の環境で撮り直す」という、このモックが存在する理由そのものが
> 果たせないため、P7-d第2段階でリポジトリへ移した。

---

## 2. 起動

端末を2つ使う。

```bash
# 端末1 — モックAPI（127.0.0.1:54321 のみ。LANからは到達しない）
npm run shots:api

# 端末2 — アプリをモックへ向けて起動（http://localhost:5199）
npm run shots:app
```

`shots:api` は起動時に `mock supabase on http://127.0.0.1:54321 (loopback only)`
と表示する。これが出ない場合は撮影を始めない。

---

## 3. 架空セッションの投入

認証が要る画面（予定ダイアログ・設定・共有ダイアログ）を開くには、ブラウザの
DevTools コンソールで次を実行する。**実在しないアドレスを使う**
（`.test` は予約TLDで、誰にも割り当てられない）。

```js
localStorage.setItem('sb-localhost-auth-token', JSON.stringify({
  access_token: 'mock', token_type: 'bearer', expires_in: 31536000,
  expires_at: Math.floor(Date.now() / 1000) + 31536000,
  refresh_token: 'mock',
  user: {
    id: '00000000-0000-4000-8000-000000000001',
    aud: 'authenticated', role: 'authenticated',
    email: 'demo@example.test',
    app_metadata: { provider: 'google', providers: ['google'] },
    user_metadata: { name: 'Demo Owner' }, identities: [],
    created_at: '2026-01-01T00:00:00.000Z',
    updated_at: '2026-10-01T00:00:00.000Z', is_anonymous: false,
  },
}));
location.reload();
```

キー名の `localhost` は、supabase-js が
`` sb-${new URL(url).hostname.split('.')[0]}-auth-token `` でキーを決めるため。
`.env.mockapi` のURLを変えるとキー名も変わる。

---

## 4. 表示言語の切り替え

**画面によって決まり方が違う。** これを取り違えると、撮ったつもりの言語と
実際の画像が食い違う。

| 画面 | 言語の決まり方 | 切り替え方 |
| --- | --- | --- |
| 認証後の画面 | `owner_settings.language` | `curl "http://127.0.0.1:54321/__scenario?language=ja"`（`en` も可）→ リロード |
| 匿名共有画面 `/s/:token` | **閲覧者のブラウザ言語** | コンソールで `navigator.languages` を上書きし、`/src/main.tsx?locale=<任意>` を動的 import して再マウント |

匿名共有画面の再マウント例:

```js
Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'], configurable: true });
document.getElementById('root').innerHTML = '';
await import('/src/main.tsx?locale=' + Date.now());
```

> リロードすると上書きは消える。**言語を変えるたびに上書きし直す。**
> クエリ名に `v` は使わない（Vite 自身のキャッシュバスト用）。

---

## 5. 匿名共有画面の状態切り替え

```bash
curl "http://127.0.0.1:54321/__scenario?fb=complete"        # Busy + Available
curl "http://127.0.0.1:54321/__scenario?fb=indeterminate"   # 判定不能
curl "http://127.0.0.1:54321/__scenario?fb=empty"           # complete だが空き時間0件
curl "http://127.0.0.1:54321/__scenario?fb=not_requested"   # 空き時間を伝えないリンク
curl "http://127.0.0.1:54321/__scenario?fb=unavailable"     # リンクが使えない
```

その他:

```bash
curl "http://127.0.0.1:54321/__scenario?saveFails=1"   # 設定保存を失敗させる
curl "http://127.0.0.1:54321/__scenario?eventsFail=1"  # 予定取得を失敗させる
```

**`unavailable` は週ナビゲーションごと出さない**設計なので、この状態から他の状態へ
切り替えるにはリロードが要る（画面にボタンが無く、再取得を起こせない）。

---

## 6. 撮影

1. 撮りたい要素の位置をコンソールで求める（`getBoundingClientRect()`）
2. スクリーンショットのフレーム幅 ÷ `window.innerWidth` の比率をかけて、
   撮影ツールの座標系に変換する
3. その領域だけを切り出す

ブラウザのクローム（タブ・アドレスバー）は含めない。

### ネイティブ `<select>` の候補リストは撮れない

展開した `<select>` のリストは**OSが描画する**ため、ページのスクリーンショットには
写らない。偽装して描き足してはいけない。

**閉じた状態を撮り、選択肢の一覧は本文の表に置く。** 第1段階の
`me-visibility-availability` はこの方針で撮っている。

---

## 7. 画像の登録（manifest）

**撮っただけでは配信されない。** `content/images/manifest.json` に登録して初めて
公開対象になる。自動登録はしない。

```json
"<画像ID>": {
  "chapter": "<対応する章のID>",
  "heading": "<対応する見出し>",
  "route": "/",
  "scenario": "<__scenario の指定など、再現に要る情報>",
  "state": "<画面の状態>",
  "viewport": "1737x1018 css",
  "langs": ["ja", "en"],
  "width": 0, "height": 0,
  "capturedAt": "YYYY-MM-DD",
  "alt": { "ja": "...", "en": "..." }
}
```

配置先は `content/images/ja/<画像ID>.png` と `content/images/en/<画像ID>.png`。

登録しないままビルドしても `dist` には出力されない（`scripts/guide-images.mjs` が
manifest を許可リストとして使う）。`npm run docs:check` は、本文が参照する画像が
manifest に無い・ファイルが無い・alt が無い・言語が食い違う場合にビルドを止める。

---

## 8. 撮影後の片付け

```js
// ブラウザ: 架空セッションとテストデータを消す
localStorage.removeItem('sb-localhost-auth-token');
localStorage.removeItem('timeweave.events.v1');
```

その後、タブを閉じ、端末1・2 の両方を停止する。

---

## 9. 品質基準（残り11種類に適用する）

| 項目 | 基準 |
| --- | --- |
| 解像度 | 等倍以上。引き伸ばさない。本文のフォントサイズで文字が読めること |
| 日英の対応 | **同じ画面・同じ状態・同じ架空データ**で撮る。違うのは言語だけ |
| 架空データ | 本書§3のユーザーとモックのシードのみ。実在しそうな人名・社名を使わない |
| トリミング | 操作対象とその文脈が分かる最小範囲。ブラウザのクロームは含めない |
| 個人情報 | `demo@example.test` 以外のアドレス、実トークン、実予定を写さない |
| 焼き込み | **番号・矢印・説明文を画像に焼き込まない。** 説明は本文の表に置く |
| モバイル | 原則デスクトップ幅。モバイル固有のUI（コンパクト月表示など）を説明する章だけ別途撮る |
| 形式 | PNG。1枚あたり概ね 100 KB 以下 |

### 撮り直しが要る条件

- 対象画面のUI文言が変わったとき（辞書のキーが変わった、文言を直した）
- レイアウトが変わったとき
- 写っている機能の挙動が変わったとき
- **片方の言語だけ変更が入ったとき**（両方撮り直して対応を保つ）

撮り直したら `manifest.json` の `capturedAt` を更新する。

### 既存6枚

第1段階で撮った6枚は**原則そのまま**。上の条件に当てはまったときだけ撮り直す。

### 撮り直しの実例（P8-finish-1・2026-10-20）

P8-mobile-2（凡例・帯の文字・終日の統一・副題）と P8-c3.1（期限の UTC オフセット）で古くなった6種類（各日英）を撮り直した:
`pa-viewer-complete`・`pa-busy-wins`・`pa-viewer-empty`・`pa-viewer-indeterminate`・`wvs-unavailable`・`sl-link-list`。
そのときの決まりごと:

- **幅を保つ**: 匿名共有画面の4種類は、ビューポートの幅を元画像の幅（825 / 793 / 733）にして、ページの枠をそのまま切り抜くと元と同じ幅になる。高さは中身（凡例・帯の文字）に合わせて増えてよい
- **「今日」を固定する**: モックの予定は 2026-10-12 の週にある。撮影ブラウザの `Date` を 2026-10-13（火）に固定すると、元画像と同じく火曜が「今日」の枠になり、期限 2026/10/20 のリンクも「有効」のまま写る
- **匿名共有画面の言語は閲覧者のブラウザ言語**: `navigator.languages` をページ読み込み前に上書きする（オーナーの `language` は使われない）
- **日英は同じ枠（同じ大きさ）で撮る**: manifest の `width` / `height` は日英で1つ。中身の長さが違う画面（`wvs-unavailable`、`sl-link-list`）は大きい方に合わせた枠で両方を撮り、枠の外に入る後続の段落は撮影時だけ非表示にする
- 撮り直し後は、同じ手順で撮った画像と**バイト単位で一致**することを確認した（表示が実装と一致している証拠）

**既知の不一致（未修正・P8-finish-2 へ）**: 英語の7種類（`gs-settings`・`me-recurrence`・`me-scope`・`pa-share-dialog`・`sl-mobile-share`・`sl-created-url`・
`tz-unset-notice`）は、実際の画像の大きさが manifest の大きさ（日本語版の大きさ）と数px〜数十px違う。
P8-finish-2 の実測: 縦横比は実画像のまま保たれ、拡大されるのは `me-recurrence`（382 → 397px）だけ。他は実寸で、読み込み前に確保した高さとの差だけ本文がずれる。

---

## 10. この手順で撮れないもの

| 対象 | 理由 |
| --- | --- |
| 展開した `<select>` の候補リスト | OSが描画するため（§6） |
| 実際のGoogle OAuth画面 | 外部IdPへの通信が必要。ログイン画面の表示までは撮れる |
| ガイド画面そのもの | ドキュメント画面がP7-e未実装 |
