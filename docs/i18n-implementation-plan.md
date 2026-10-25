# i18n 段階的実装計画

**状態: 計画のみ。実装は未着手。着手は別途指示。**

設計は `docs/i18n-architecture.md`。本書は「どの順で、何を壊さずに進めるか」だけを扱う。

---

## 全体方針

**言語切替が効くようになるのは最終フェーズだけ。** それまでの各フェーズは
「画面は常に日本語」という現状を1ミリも変えない。これが安全性の中心で、
途中で切替を有効にすると「English を選んだのに日本語のまま」という
もっとも悪い状態が長期間続く。

```
P1 基盤          ユーザーに見える変化: なし
P2 配線          ユーザーに見える変化: なし
P3 文言移行      ユーザーに見える変化: なし（日本語のまま）
P4 日付・曜日    ユーザーに見える変化: なし（ja ロケールで同一表示）
P5 英訳          ユーザーに見える変化: なし（en 辞書を用意するだけ）
P6 切替解禁      ★ここで初めて効く。注記を外す
P7 ドキュメント  別系統・任意
```

各フェーズ単独で commit / deploy 可能で、どこで止めても壊れない。

---

## P1 — 基盤（純粋モジュールのみ）

**対象ファイル（すべて新規）**

```
src/i18n/types.ts            Language, MessageKey
src/i18n/ja.ts               日本語辞書（この時点では空に近い）
src/i18n/en.ts               Record<MessageKey, string>
src/i18n/resolveLanguage.ts  言語解決の純粋関数
src/i18n/t.ts                t(key, lang, params?) と補間
src/i18n/resolveLanguage.test.ts
src/i18n/t.test.ts
```

**実装範囲**: 既存ファイルを1つも変更しない。純粋関数と型だけを足す。

**テスト**

```
resolveLanguage  stored 優先 / null→browser / ja-JP・en-US・en-GB の前方一致
                 未対応言語（fr-FR）→ ja / browser 空 → ja
                 匿名（stored=null）は常に browser に従うこと
t                キーの解決 / 補間 / 未知キーの扱い（キー文字列を返す＝無言で空にしない）
型               en からキーを1つ削ると tsc が落ちること（意図的失敗を手動確認）
```

**完了条件**: 既存770テストが無改変で PASS。新規テストが PASS。tsc・build PASS。

**リスク**: ほぼ無い。既存コードへの参照が0なので、最悪でも未使用コードが増えるだけ。

---

## P2 — 配線（言語を解決して配るが、まだ使わない）

**対象ファイル**

```
新規  src/i18n/useLanguage.ts       owner_settings と navigator から解決
変更  src/App.tsx                   解決した言語を Context で配る
変更  src/features/settings/SettingsDialog.tsx   保存後に再解決（画面は変わらない）
```

**実装範囲**: `navigator.languages` を読む箇所を**1つだけ**作る。
Context は値を配るだけで、消費者はまだ居ない。

**注意**: 匿名共有ページは `owner_settings` を読めない（RLS・権限とも拒否）。
**読もうとしてはいけない。** 匿名側は `stored: null` 固定でブラウザ言語のみを使う。
ここを間違えると匿名ページがエラーになる。

**テスト**: `useLanguage` の解決ロジックは P1 の純粋関数に委譲済みなので、
配線自体のテストは書けない（jsdom 無し）。代わりに
**「匿名ルートで owner_settings を参照しない」ことをソース走査で固定**する。

**完了条件**: 画面の表示が1文字も変わらないこと。全テスト PASS。

**リスク**: 匿名ページで設定を読みに行く実装をすると 42501 で画面が壊れる。
上記のソース走査テストがその再発を防ぐ。

---

## P3 — 文言移行（日本語のまま辞書経由にする）

**順序が重要。** 既に純粋モジュールに集約されているものから始める。

### P3-a 純粋モジュール（移行が容易・テストが既にある）

```
errors.ts                      18行 / 11クラス
features/share/freeBusyBanner.ts, freeBusyPresentation.ts, availablePresentation.ts
features/settings/timezoneSetting.ts
features/calendar/eventTitle.ts, visibilityMeta.ts
services/contentLimits.ts
features/event/recurrenceForm.ts
```

**既存61アサートのうち約50はここに属する。** 移行後も
`expect(t('error.quotaEvents', 'ja')).toContain('上限')` の形で同じ検証を続ける。
**テストを削除・弱体化して通さない。**

> `errors.ts` には設計上の論点が1つある。`Error` クラスはコンストラクタで
> 文言を確定するが、言語はレンダリング時に決まる。**メッセージではなくキーを持たせ、
> 表示側で `t()` する**形に変える。`WriteRateLimitedError.retryAfterSeconds` のように
> 既に「値をフィールドで持ち、文言は別」という形になっているものがあり、
> その方針を全クラスに広げることになる。これは P3 で最も設計判断を要する部分。

### P3-b コンポーネント（量が多い・機械的）

```
ShareDialog 36 → EventDialog 34 → FreeBusyPage 15 → RecurrenceEditor 15
→ SettingsDialog 12 → CalendarToolbar 6 → 残り
```

1ファイルずつ、1 commit ずつ。各 commit で
**「このファイルに日本語リテラルが残っていない」**ことを走査テストに追加していく。

**完了条件**: 全テスト PASS。画面の表示が1文字も変わらないこと（ja 辞書が元の文字列を
そのまま持つため、差分は構造だけになる）。

**リスク**

```
文言の取り違え    辞書化の際のコピーミス。ja 辞書の値を元ファイルと diff して確認する
エラー文言の欠落  catch で message を表示している箇所がキー化で壊れる。
                 P3-a の errors.ts を最初にやる理由がこれ
テストの空洞化    「t() が何か返すこと」だけを見るテストに退化させない。
                 文言の内容（何を言い、何を言わないか）を引き続き検証する
```

---

## P4 — 日付・時刻・曜日

**対象ファイル**

```
変更  utils/datetime.ts                  locale 引数を必須化するか、呼び出し側で渡す
変更  features/calendar/monthGrid.ts, weekGrid.ts
変更  features/calendar/DayAgendaDialog.tsx   toLocaleDateString(undefined,…) → 解決済み locale
変更  features/share/ShareDialog.tsx          toLocaleString() → 解決済み locale
新規  src/i18n/weekdayLabels.ts               4箇所のハードコード配列を1関数へ統合
変更  MonthView.tsx, TimeGridView.tsx, FreeBusyPage.tsx, RecurrenceEditor.tsx
```

**触らないもの（再掲・重要）**

```
utils/timezone.ts:98   Intl.DateTimeFormat('en-US', …)   ゾーン名の検査であって表示ではない
週の開始曜日            月曜固定。変えると 0024/0025 の窓が変わり Free/Busy が変わる
```

**テスト**: `weekdayLabels('ja')` / `('en')` の純粋関数テスト。
`ja` で既存のハードコード配列と**完全一致**することを固定する（表示が変わらない証拠）。

**完了条件**: ja での表示が P3 完了時と同一であること。

**リスク**: 週開始曜日をロケール由来にしてしまうと匿名共有の計算が変わる。
上記テストと、`weekStartDayKey` を変更しないことで防ぐ。

---

## P5 — 英訳

**対象**: `src/i18n/en.ts` のみ。コードは変更しない。

**完了条件**

```
tsc が通る（＝キー欠落ゼロ）
ja と en が同一文字列のキーが0件（翻訳忘れ検出テスト）
```

**リスク**: 翻訳の品質。特に**安全性に関わる文言**は意味を変えてはならない。

```
AVAILABLE_INDETERMINATE_MESSAGE   「判定できなかった」を「空きが無い」にしない
UNAVAILABLE_MESSAGE               理由を一切名指ししない（0023 の設計）
ACTIVE_EMPTY_MESSAGE              「共有されている予定が無い」であって
                                  「予定が無い」ではない
TIMEZONE_CHANGE_NOTICE            「時刻ありの予定は変わらない」を落とさない
```

これらは既存テストが「何を言わないか」を検査しているので、
**同等の否定アサートを en 側にも書く**こと。

---

## P6 — 切替の解禁（★ユーザーに見える唯一のフェーズ）

**対象ファイル**

```
変更  各コンポーネント        t(key) に解決済み言語を渡す（Context を実際に消費）
削除  timezoneSetting.ts      LANGUAGE_PENDING_NOTICE と、それを表示する行
変更  timezoneSetting.test.ts 「まだ有効になっていません」のアサートを削除し、
                              代わりに「切替が効く」ことを検証するものに置き換える
```

**完了条件**

```
設定を en にして再読み込み → 画面が英語になる
設定を ja → 日本語
未設定 + ブラウザ en        → 英語
未設定 + ブラウザ fr        → 日本語
匿名共有ページがブラウザ言語に従う（オーナー設定に従わないこと）
Free/Busy の計算結果が言語によって変わらないこと（同一入力で slots が一致）
```

**最後の1行が最重要の回帰確認。** 言語を変えて匿名共有ページを開き、
`get_free_busy` のレスポンスが**バイト単位で同一**であることを確認する。

**リスク**

```
P5 の翻訳漏れが本番で露出     P5 の完了条件（tsc + 同一文言0件）で防ぐ
注記を外すのが早すぎる         P3〜P5 がすべて完了するまで P6 に入らない
匿名ページがオーナー言語に従う  P2 の走査テストで防ぐ
```

---

## P7 — ドキュメント（別系統・任意）

アプリの i18n とは独立に進められる。P1 の `resolveLanguage` だけを共有する。

```
P7-a  src/routing/route.ts（parseRoute 純粋関数）＋テスト。画面には出さない
P7-b  docs/content/{ja,en}/ の骨組みと front-matter 規約
P7-c  sourceHash による翻訳鮮度チェック（テストまたは CI）
P7-d  描画（Markdown レンダラ選定はこの時点で行う）
```

**P7-a だけ先に入れておく価値がある。** `App.tsx` の正規表現1本を純粋関数に移すのは
それ自体が改善で、ドキュメントを足すときの前提になる。

### P7-a 完了時点の実際（2026-10-13）

上の計画との差分:

- 配置は `docs/content/` ではなく **`content/`**（リポジトリ直下）。`docs/` は内部設計
  資料専用のままにし、「`content/` 配下＝公開」を1文の不変条件として保つため。
- `parseRoute` は 5 種の Route を返す（`share` / `docsIndex` / `docsPage` /
  `docsNotFound` / `app`）。未知の2文字言語と不正なIDはいずれも `docsNotFound`。
- `popstate` 購読（`src/routing/useRoute.ts`）を同時に入れた。従来は戻る・進むで
  URL だけが動き画面が追従しなかった。
- 公開ルート判定フラグを `isShareRoute` → **`isPublicRoute`** に改名。共有ページと
  ドキュメントの両方が `owner_settings` を取得しないことを同じ名前で表すため。

### P7-c の前提条件 — 公開範囲の比較表は実装と照合してから書く

ユーザーガイドで最も誤解が事故に直結するのは `visibility` と共有リンクの2つの
オプトインの関係である。**記憶で書かず、必ず以下を根拠にすること。**

**確認済み（2026-10-13、migration と SQL テストで照合）**:

`private` かつ `available` な予定が匿名閲覧者に開示されるのは、
**`share_available=ON` と `include_private=ON` の両方が成立するときだけ**である。
`share_available=ON` だけでは開示されない。

- 根拠1: `0024_freebusy_available.sql` の `free_busy_available` 内に
  `(v_include_private or e.visibility <> 'private')` が7箇所あり、available 集合の
  算出自体から private 予定を除外している。
- 根拠2: `supabase/tests/0024_available_test.sql` §6 がこの4通りを直接検証している。

```
6.1  share_available=F / include_private=T  -> not_requested
6.2  share_available=F / include_private=F  -> not_requested
6.3  share_available=T / include_private=T  -> 両方の時間帯を開示
6.4  share_available=T / include_private=F  -> public な方だけ。
                                               private 予定の「時刻」が漏れないことが要点
```

表の他のセル（`busy_only`、`public`、Busy優先、3状態）も同様に
`0021_*` / `0022_*` / `0024_*` のテストと1セルずつ突き合わせてから公開する。
プライバシーの説明を推測で書くのは、誤った安心を与える点で無記載より危険である。

---

## フェーズ間の依存と停止点

```
P1 → P2 → P3 → P4 → P5 → P6
                         ↑ ここだけがユーザーに見える
P7 は P1 以降いつでも独立に実行可
```

```
安全に止まれる点   P1完了後 / P2完了後 / P3の各ファイル完了後 / P4完了後 / P5完了後
止まってはいけない  P6 の途中（一部だけ英語になる）
```

P6 は1コミットで完結させる。

---

## 見積りの目安（参考・実測ではない）

```
P1  小    純粋関数とテストのみ
P2  小    配線1箇所と走査テスト
P3  大    196行の移行。純粋モジュール→コンポーネントの順で約10コミット
P4  中    4箇所の曜日統合と locale の引き回し
P5  中    約200キーの英訳。安全性文言のレビューを含む
P6  小    注記の削除と回帰確認
P7  中    骨組みのみなら小。描画まで含めると中
```

---

## この計画が守るもの

```
Free/Busy の計算        言語は SQL に到達しない（0025 postflight H02 が参照0件を固定）
権限・RLS・開示条件      無関係
週の開始曜日             月曜固定
ゾーン検査の 'en-US'     表示ではないので対象外
既存テスト               削除・弱体化しない。61アサートは t() 経由で等価に残す
暫定状態の正直さ         P6 まで「まだ有効になっていません」の注記を外さない
```
