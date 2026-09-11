# TimeWeave

個人用スケジューラー兼・空き時間共有 Web アプリ。React + TypeScript + Vite。

本番: https://timeweave-five.vercel.app （ホスティング: Vercel / DB・認証: Supabase）

## セットアップ

```bash
npm install
npm run dev        # 開発サーバー
npm test           # ロジックの単体テスト
npm run build      # 型チェック + 本番ビルド
```

### 環境変数と動作モード

`.env.example` を `.env` にコピーして設定。

- **未設定（ローカルモード）**: 認証なし・`localStorage` に保存。秘密情報なしでそのまま動作。
- **設定済み（Supabaseモード）**: Google ログイン必須・DB 保存（RLS で本人のみ）。

```
VITE_SUPABASE_URL=...        # Supabase Project URL
VITE_SUPABASE_ANON_KEY=...   # Supabase anon key（公開前提。RLSが実際の防御）
```

### Supabase セットアップ（Supabaseモードを使う場合）

1. Supabase プロジェクトを作成し、URL / anon key を `.env` に設定。
2. `supabase/migrations/` を番号順に SQL エディタ（または Supabase CLI）で適用。
   - `0001_events.sql`: `events` テーブル・インデックス・`updated_at` トリガ・RLS
   - `0002_events_grants.sql`: `authenticated` ロールへの最小 DML 権限
   - `0003_exception_unique.sql`: 繰り返し例外の重複防止（部分 UNIQUE INDEX 2 本）
   - `0004_share_links.sql`: 共有リンク（トークンは sha256 ハッシュのみ保存）
   - `0005_free_busy_rpc.sql`: SECURITY DEFINER RPC 4 本（共有の唯一の入口）
   - `0006_rrule_parser.sql`: SQL 側 RRULE パーサ（展開はせず narrowing のみ）
   - `0007_allday_recurrence_freebusy.sql`: all-day 繰り返しの Free/Busy 展開
   - `0008_events_timezone.sql`: `events.timezone` 列と書き込み時の状態機械
   - `0009_timed_recurrence_freebusy.sql`: timed 繰り返しの展開（DST 対応）
   - `0010_count_freebusy.sql`: `COUNT` 付き繰り返しの展開

   `0006` 以降は `supabase/tests/` に preflight / postflight / テストスイートがある。
   適用前に preflight、適用後に postflight とテストスイートを実行する運用
   （テストスイートは `begin; … rollback;` でフィクスチャを残さない）。
3. Authentication → Providers で **Google** を有効化し、Google Cloud の OAuth
   クライアント ID / Secret を設定。Authorized redirect に Supabase のコールバック URL、
   アプリ側 Redirect URL に `http://localhost:5173`（開発）と本番 URL
   （`https://timeweave-five.vercel.app`）を登録。`signInWithOAuth` は
   `redirectTo: window.location.origin` を送るため、許可リストにないドメインからは
   ログインが失敗する。

## アーキテクチャ（レイヤー分離）

UI・データアクセス・スケジュール計算を分離し、各レイヤーを差し替え可能にする。

| レイヤー | 場所 | 責務 |
|---|---|---|
| UI | `src/features/`, `src/App.tsx` | 表示とユーザー操作のみ |
| hooks | `src/hooks/` | repository と service を束ねて UI へ供給 |
| repositories | `src/repositories/` | データ永続化。**ここだけ**が保存先を知る |
| services | `src/services/` | 純粋なスケジュール計算（React/DB 非依存・テスト対象） |
| utils | `src/utils/` | 日時変換の一元化、ID 生成 |
| types | `src/types/` | ドメイン型 |

**データアクセスの差し替え**: UI/hooks は `EventRepository` インターフェースにのみ依存。
Phase 1 は `LocalStorageEventRepository`、Phase 2 で `SupabaseEventRepository` を
`getEventRepository()` で差し替えるだけ（UI 無変更）。

**日時**: 保存・受け渡しは UTC ISO 文字列。表示のみローカルタイムへ変換。
変換は必ず `utils/datetime.ts` 経由（文字列操作禁止）。将来のタイムゾーン演算も
このファイル内部だけで対応。

**テーマ**: 配色トークンは `styles/theme.css`（`data-theme` 属性で切替）、初期テーマの判定規則は
`utils/theme.ts` の純粋関数、`data-theme` の適用と `localStorage` への保存は `App.tsx` が持つ。
コンポーネントは色を直接書かない。

## RRULE 対応サブセット

繰り返しは基本予定 1 件 + RRULE で保持し、表示期間だけ展開する（事前大量生成しない）。
パースは `services/recurrence.ts` に集約し、下記サブセット外は
`UnsupportedRRuleError` を投げる（**黙って誤解釈しない**）。将来 rrule.js 等へ
差し替える場合もこのファイルのみ変更。

- `FREQ` = `DAILY` | `WEEKLY` | `MONTHLY`（必須）
- `INTERVAL`（隔週 = 2 など）
- `BYDAY` = `MO,TU,WE,TH,FR,SA,SU`（WEEKLY 限定、序数付き `2MO` は非対応）
- `COUNT` **xor** `UNTIL`（併用不可、両方省略で無限）
- 上記以外のキー（`BYMONTHDAY` 等）は非対応 → エラー

### MONTHLY の月末（RFC 5545 の skip semantics）

`MONTHLY` は基準日（DTSTART）の day-of-month を各月に当てはめる。**その日が存在しない
月は occurrence を生成せず、その月ごとスキップする**（RFC 5545 準拠）。

- 例: DTSTART = 1/31 → 2月・4月・6月・9月・11月は生成しない
- 例: DTSTART = 2/29 → 閏年の2月にのみ生成する
- **スキップされた月は `COUNT` を消費しない**（`COUNT=3` は必ず実在の3回を返す）
- JS の `Date` は存在しない日付を翌月へ繰り上げる（1/31 + 1ヶ月 → 3/3）。この
  rollover による誤生成を `services/recurrence.ts` で明示的に検出・排除している

## 開発フェーズ

- **Phase 1（完了）**: 月カレンダー、前/次/今日、予定 CRUD、localStorage 永続化、テスト
- **Phase 2（完了）**: Supabase 導入、Google ログイン（`auth/`）、`events` + RLS、
  `SupabaseEventRepository` 切替、終日予定（日付ベース・end 排他的）、繰り返し例外の
  型安全なスロット識別（timed=`recurrence_slot_start` / all-day=`recurrence_slot_date`）
- **Phase 2（実地検証済み）**: 実 Supabase プロジェクトで Google ログイン〜CRUD〜
  リロード保持〜RLS越し不可視（他ユーザーは `[]`）〜`owner_id = auth.uid()`〜終日
  `start_date/end_date`（排他的）保存まで確認済み
- **Phase 3（完了）**: 週/日表示（0–24h・初期8:00スクロール・時間帯クリック作成）、
  複数日終日予定の帯表示（週ごとに分割・月/週跨ぎ継続表示）、カテゴリ自動配色（安定ハッシュ）、
  visibility のアイコン+ラベル表示。時間配置・重なり列（衝突グループ単位）・終日帯レーン割当・
  配色・タイムゾーン処理は純粋関数化しテスト済み（date-fns-tz、DST安全）
- **Phase 4（完了）**: 繰り返し予定 UI（`RecurrenceEditor`）、繰り返し例外（この回のみ
  変更/削除／すべて変更・削除）。例外行は**完全スナップショット**として保持し、例外がある
  系列の「すべて変更」は `SeriesEditBlockedError` で拒否（スナップショットが陳腐化するため）。
  「すべて削除」はマスター削除＋例外カスケードで許可。編集オーケストレーションは純粋関数
  `services/recurrenceOps.ts`（+ `exceptionEdit.ts` / `seriesGuards.ts`）に分離しテスト。
  同一マスター・同一スロットへの例外重複は DB の部分 UNIQUE INDEX（`0003`）で防止し、
  SQLSTATE 23505 → `DuplicateExceptionError` に変換。all-day の `UNTIL` は DATE のまま
  （UTC変換しない）、timed は UTC instant。「この予定以降」は将来対応（未実装）。
- **Phase 4（実地検証済み）**: 実 Supabase 環境で 繰り返し作成〜展開、「この回のみ」変更/削除、
  「すべて変更」の拒否、「すべて削除」のカスケード、all-day 繰り返し（UNTIL 付き）まで確認。
  timed 例外のスロット照合ずれ（timestamptz 往復のISO表記差）と all-day 繰り返しの帯配置
  （マスター日付参照）の2不具合を検証中に発見・修正（下記「修正履歴メモ」）。例外重複
  （23505→`DuplicateExceptionError`）は自動テスト＋DB制約で担保（通常UI操作では再現困難）。
- **Phase 5a（完了・本番稼働中）**: 共有 URL（`/s/:token`）と
  匿名 Free/Busy 表示。
  `share_links` テーブル（`0004`）とマイグレーション `0005` の SECURITY DEFINER RPC 4本
  （`create_share_link` / `list_share_links` / `revoke_share_link` / `get_free_busy`）で構成。
  カレンダー右上「共有」ボタン（Supabaseモード時のみ表示）から `ShareDialog` で
  作成 / 一覧 / 失効 / URLコピーができ、`include_private` と `expires_at` を作成時に指定する。
  閲覧側 `FreeBusyPage` は `AuthGate` の外側でレンダリングされ、週送り以外の操作を持たない
  完全な読み取り専用。詳細は下記「共有のセキュリティ境界（Phase 5a）」。
  本番では、未ログインのシークレットウィンドウから `/s/<token>` を直接開いて Free/Busy が
  表示されること、リロードしても 404 にならないこと、予定のタイトル・内容が出ないことを
  ブラウザで確認済み。
- **Phase 5b-0（実装済み・実DB検証済み）**: SQL 側 RRULE パーサ（`0006`）。展開はまだ行わず、
  「UNTIL から終了済みと証明できる series」を completeness 判定から除外する narrowing のみ。
- **Phase 5b-1（完了・実DB検証済み）**: all-day の `FREQ=DAILY` / `FREQ=WEEKLY` を
  Free/Busy へ展開（`0007`）。例外行とキャンセルも解決する。詳細は下記
  「繰り返しの Free/Busy 展開」。
- **Phase 5b-2（完了・実DB検証済み）**: `events.timezone` 列を追加（`0008`）。timed 繰り返し
  マスターだけがゾーンを持つという状態機械を CHECK + BEFORE トリガで DB 側に強制し、
  TypeScript 側は `services/timezoneRules.ts` がその写しを持つ。既存行の backfill はしない
  （ゾーンを推測すると系列の意味が変わるため）。
- **Phase 5b-3（完了・実DB検証済み）**: timed 繰り返しの Free/Busy 展開（`0009`）。
  各回は master のゾーンの壁時計時刻で解決し、PostgreSQL の `AT TIME ZONE` と同じ規則を用いる
  （存在しない時刻＝gap は変換後に 1 時間後へずれ、曖昧な時刻＝fold は**後の**インスタンスになる。
  どちらも標準時オフセットでの解決結果で、こちらで発明も上書きもしない）。解決できないゾーンと、
  ゾーンを持たない legacy マスターは展開せず `complete=false` に倒す。
- **Phase 5b-4（完了）**: TypeScript 側の展開を `0009` の DST 意味論に合わせた
  （SQL 変更なし）。ブラウザのローカルゾーンではなく `events.timezone` を基準に展開する。
- **Phase 5b-5A（完了）**: TypeScript 側の展開候補をウィンドウから逆算する方式に変更し
  （SQL 変更なし）、`COUNT` を「走査しながらの計数」から**序数の上界**へ改めた。
  `BYDAY` は常に曜日順へ正規化する（順序が occurrence の**集合**を変えていた不具合の修正）。
- **Phase 5b-5B（完了・実DB検証済み）**: `COUNT` 付き繰り返しを SQL 側でも展開（`0010`）。
  all-day / timed の DAILY・WEEKLY に対し、TypeScript と同一の閉形式の序数契約を用いる。
  終了済みの `COUNT` 系列は `complete=true` / `slots=[]` を返すようになった（従来は終了を
  証明できず `complete=false` に倒れていた）。
- Phase 5b で残っているのは **SQL 側の `FREQ=MONTHLY` 展開**（未着手）。
  現状は `complete=false` に倒している。
- **Phase 6-1（完了・本番確認済み）**: 初回ロード中に空のカレンダーを描画しない。
  空のグリッドは「予定がない」という主張なので、最初の行が届くまでは代わりに「読み込み中…」を
  出す。判定は `features/calendar/loadState.ts` の純粋関数 `isAwaitingRows()`＝`loading` かつ
  手持ちの行が 0 件。`loading` 単独ではないのは `useEvents` が保存・削除のたびに再取得するため
  で、行が手元にある限りグリッドは消さず再取得は画面に出さない。取得失敗は従来どおり別扱いで、
  エラーバナーが担当する。空のカレンダー自体には注記を出さない（それは正常な画面であり、
  新規作成の導線でもある）。
- **Phase 6-2（完了・本番確認済み）**: ダークモードの仕上げ。現在の契約は次のとおり。
  - `color-scheme` を両テーマに宣言し、ブラウザ自身が描く UI（`date` / `datetime-local` の
    ピッカー、`select`、チェックボックス、スクロールバー）をテーマへ追従させる。
  - テーマ依存色は `styles/theme.css` のトークンに集約する。コンポーネントと `global.css` は
    色を直接持たない（唯一の例外はモーダルの半透明の黒で、両テーマで意図どおり機能する）。
  - danger / warning 系を含め、テーマ依存のテキスト配色はライト・ダークとも WCAG AA の
    通常テキスト基準（4.5:1）を満たす。
  - 初期テーマの優先順位は **保存値 > OS 設定 > light**。判定は `utils/theme.ts` の純粋関数
    `resolveInitialTheme()`。読めない保存値は「保存なし」として扱い OS 設定へフォールバックする。
  - 手動で選んだテーマは `localStorage['timeweave.theme']` に保存され、以後 OS 設定より優先される。
  - OS テーマ変更へのリアルタイム追従はしない（下記「既知の制約」）。
- Phase 6 は進行中。残件はドラッグ&ドロップ、レスポンシブ改善、キーボード操作、favicon / OGP、
  および下記「既知の制約」に挙げた任意 TZ 選択 UI・月ビュー帯レイアウトの調整・作成直後の
  月移動導線。

## TODO / 既知の制約

- **複数日終日予定の帯表示（Phase 3 で実装済み）**: 月/週/日ビューで横帯として描画。
  月ビューは週ごとに帯ストリップを持ち、週跨ぎで分割、月跨ぎは `‹`/`›` で継続を表示。
  レーン数は `MAX_ALL_DAY_LANES` で上限、超過分は列ごとに `+N` を表示（`buildAllDayBands`
  が `overflow` を返す）。DB 設計と `[start_date, end_date)` 排他仕様は不変（描画側のみ）。
- **タイムゾーン**: 週/日/時間グリッドはユーザーの IANA ゾーン（既定はブラウザの
  `Intl` 解決値）を明示的に用い、実行環境ローカル TZ に暗黙依存しない。全 TZ 変換は
  `utils/timezone.ts` に集約（date-fns-tz、DST安全）。終日は date のまま扱い UTC 変換しない。
  なお予定入力ダイアログ（`datetime-local`）はブラウザローカル時刻ベース。将来ユーザーが
  任意 TZ を選べるようにする場合はダイアログ側も同ゾーンへ合わせる必要がある（Phase 6）。
- **月ビューの帯レイアウト**: 各週で「帯ストリップ＋日セル」を縦に積む方式（Google の
  セル内オーバーレイとは異なる簡易版）。視認性は満たすが、より一体的な見た目は Phase 6 で検討。
- **月ビュー終日帯が週境界付近に張り付いて見える**（機能は正常）: UX 改善候補。帯の
  余白/角丸/継続マークの見せ方を Phase 6 で調整。
- 参考（UX）: リロード時は表示月が当月に戻るため、他月に作成した予定は画面外になる。
  将来「作成直後にその月へ移動」等の導線を検討（Phase 6）。
- **SQL 側の `FREQ=MONTHLY` は未展開（Phase 5b の残件）**: 月次の繰り返しを持つ owner の
  共有ページは、その予定が触る期間で常に `complete=false`（警告バナー）になる。TypeScript 側は
  MONTHLY を展開するが、その実装は 5b-4 / 5b-5A の対象外で、ゾーン非対応（ローカル時刻のまま）
  かつ候補を DTSTART から走査する方式のまま（`services/recurrence.ts` に理由を明記）。
- **all-day の陳腐化した例外を検出しない**: timed 側（`0009`）は、例外のスロットキーが生成された
  どの回とも一致しない場合に `complete=false` へ倒すが、all-day 側に同じ検査がない。ずれる方向は
  「busy を余分に出す」側なので空きを誤表示することはないが、対称ではない。
- **ゾーンを持たない legacy な timed マスター（`0008` 以前の行）のうち、例外を持つものは
  後からゾーンを設定できない**: 例外スナップショットが陳腐化するため `setSeriesTimezone` が
  `SeriesEditBlockedError` で拒否する（`services/recurrenceOps.ts`）。該当する系列は
  `complete=false` のままになる。
- **テーマは OS 設定の変更にその場では追従しない**: `prefers-color-scheme` を読むのは初期値を
  決めるときだけ（`utils/theme.ts`）。ページを開いたまま OS を切り替えても変わらず、リロードで
  反映される。`matchMedia` の変更イベントは購読していない。テーマは `'light' | 'dark'` の 2 値で、
  `'system'` という状態は持たない。
- **共有ページ（`/s/:token`）にはテーマ切替 UI がない**: トグルはヘッダにあり、共有ルートは
  ヘッダごと描画されないため（`App.tsx`）。ただし `data-theme` の適用自体は共有ルートでも走るので、
  閲覧者には保存テーマがあればそれ、無ければ OS 設定に従った配色で表示される。現時点では
  意図した仕様。
- **ダークモードの目視確認の範囲**: カレンダー、`EventDialog`、input / textarea / select /
  checkbox、`datetime-local` のネイティブ date/time ピッカー、モーダルの背景、削除ボタン、
  `ShareDialog`（既存リンクカード・失効ボタン・スクロール）、および初期テーマの 4 通り
  （保存値なし × OS dark / light、手動 light / dark を選んだ後のリロード）は本番ブラウザで
  確認済み。一方、`share-warn` の特定状態、`complete=false` の警告バナー、RPC 失敗バナーの
  ダーク表示は**本番で故意に再現していない**。これらはコントラスト計算・コード監査・単体テストで
  担保している。

### 修正履歴メモ
- Phase 3 実地検証で、週/日ビューの `segmentForDay()`（`features/calendar/timeGrid.ts`）に
  日別交差判定が無く、対象日より後の予定が手前の各日へ誤複製される不具合を発見・修正。
  `if (startKey > dayKey || endKey < dayKey) return null;` を追加し、日跨ぎ/半開境界を含む
  回帰テスト7件を `timeGrid.test.ts` に追加済み。
- Phase 4 実地検証で、timed 繰り返し例外のスロット照合を発見・修正（`services/occurrences.ts`）。
  例外の `recurrence_slot_start` が Postgres `timestamptz` 往復で `…+00:00`（ミリ秒省略）表記
  になり、展開側の `toISOString()`（`…000Z`）と**文字列一致しない**ため元 occurrence を除外
  できず二重表示していた。timed のみ `new Date(v).getTime()` で instant 正規化する単一関数
  `normalizedSlotKey(value, allDay)` を導入し、例外側・生成側の両方が必ず通す構造に統一
  （all-day は `YYYY-MM-DD` 文字列比較を維持、不正値は `null` で無言衝突を防止）。
- Phase 4 実地検証で、all-day **繰り返し**の月表示帯が全回マスターの `start_date` に集約される
  不具合を発見・修正（`features/calendar/allDayBands.ts`）。繰り返しでは `occ.event` が共有
  マスターのため、帯範囲を `occ.event.startDate/endDate` ではなく per-occurrence の
  `localDayKey(occ.start)` / `localDayKey(occ.end)` から導出するよう変更（DB仕様・保存形式・
  型・RRULE展開は不変）。展開自体は正しく各回別日で生成されており、配置側のみの修正。

## セキュリティ方針（Phase 2 以降）

- アクセス制御は Row Level Security で DB 側に強制する。フロント非表示に依存しない。
- 共有相手へは `events` を直接公開せず、RPC（`get_free_busy`）経由で最小の Free/Busy
  情報のみ返す。返すのは可用性を表す区間だけで、時間モデルごとに形が分かれる:
  - timed  : `{ all_day: false, start, end }`（UTC ISO instant）
  - all-day: `{ all_day: true, start_date, end_date }`（`YYYY-MM-DD`、end 排他）

  タイトル・ID・カテゴリ等の予定詳細は SQL でも型でも読まず、DB から出さない。

### 共有のセキュリティ境界（Phase 5a）

境界は **DB 側の SECURITY DEFINER 関数**に置く。フロントの分岐は UX であり、防御ではない。

- **テーブルは非公開**: `share_links` は `anon` / `authenticated` の双方から
  `revoke all`（`0004`）。owner-only の RLS ポリシーは多層防御として残す。
  `events` は匿名ロールに一切公開しない。
- **到達可能な唯一の入口**: `0005` の4関数のみ。いずれも `security definer` +
  `set search_path = ''`（全オブジェクトをスキーマ修飾）。DEFINER は RLS を迂回するため、
  管理系3本は `owner_id = auth.uid()`、`get_free_busy` はトークンから解決した owner で
  明示的に絞り込む。`execute` は PUBLIC から revoke し、管理系は `authenticated`、
  `get_free_busy` のみ `anon` + `authenticated` に付与する。
- **トークンはハッシュのみ保存**: サーバ側で 256bit 生成し、`sha256` の hex だけを
  `token_hash` に保存する。平文は `create_share_link` が**一度だけ**返し、以後どこにも
  残らない（`list_share_links` は返さない）。DB が漏洩しても有効な URL は復元できない。
  UI もこの性質を明示し、再表示不可・分からなくなったら失効して作り直す運用とする。
- **無効トークンはエラーにしない**: 失効・期限切れ・不存在はいずれも空の Free/Busy を返す
  （存在オラクルを作らない）。一方、**不正・92日超のウィンドウは `22023` で拒否**する
  （切り詰めた結果を完全な回答と誤認させないため）。
- **返すのは可用性のみ**: タイトル・ID・カテゴリは SQL でも型（`FreeBusySlot`）でも読まない。
  busy 区間は重複だけでなく**隣接（接触）も結合**するため、件数や個々の予定境界は漏れない。
  結合はサーバ側で実施し、表示直前に `mergeFreeBusySlots` で再結合する（多層防御）。
- **2つの時間モデルを混在させない**: timed は UTC instant 窓（`p_from`/`p_to`）、
  all-day は**ローカル日付**窓（`p_from_date`/`p_to_date`、半開）で処理し、終日を
  タイムゾーン変換しない。両窓は `FreeBusyPage` が同一の表示レンジから生成する。
- **`include_private`**: `false` の共有リンクでは private の予定を busy 集合から除外する。
  busy 抽出と後述の `complete` 判定の**両方**に同じ条件が掛かる。
- **Referrer 抑止**: 共有 URL にトークンが含まれるため、`index.html` に
  `<meta name="referrer" content="no-referrer">` を置き、さらに `vercel.json` で
  `Referrer-Policy: no-referrer` を**全レスポンス**に付与する（下記「デプロイ構成（Vercel）」）。
  meta は初期ナビゲーションや一部サブリソースを取りこぼしうるため、2 層で防ぐ。

### 繰り返しの Free/Busy 展開

匿名 Free/Busy で展開するのは **`FREQ=DAILY` / `FREQ=WEEKLY`**（all-day・timed の両方）で、
`INTERVAL`、`BYDAY`（WEEKLY 限定）、`UNTIL`、`COUNT` に対応する。
**`FREQ=MONTHLY` だけが未対応**で、`complete=false` に倒す。

SQL 側のサブセットは、上記「RRULE 対応サブセット」（TypeScript 側）から `MONTHLY` を
除いたものになっている。`UNTIL` の値型は時間モデルに従う（all-day は DATE、timed は instant）。
`COUNT` と `UNTIL` の併用はパーサが malformed として弾くため、両方が同時に効くことはない。

timed 系列は master の `events.timezone`（`0008`）の壁時計時刻で解決する。ゾーンを解決できない
場合と、ゾーンを持たない legacy マスターは展開せず `complete=false` に倒す。

- **展開の意味論は `services/recurrence.ts` と一致させる**: WEEKLY の週アンカーは DTSTART の
  週の月曜（RFC 5545 の既定 `WKST=MO`）、active week は DTSTART の週を第0週として
  `INTERVAL` 週ごと、`BYDAY` 省略時は DTSTART の曜日、`UNTIL` は occurrence の**開始日に対して
  inclusive**、第0週で DTSTART より前の曜日は生成しない。
- **occurrence は `[start_date, end_date)` の半開区間**で、master の duration を各回へそのまま
  適用する。展開候補はウィンドウから閉形式で逆算するため、DTSTART が何年前でも走査量は
  ウィンドウ幅に比例する。
- **detach と visibility を分離する**。例外行は visibility に関係なく
  `recurrence_slot_date` で元 occurrence を detach する（series 構造の事実）。
  visibility を評価するのは**その例外の snapshot を busy に加えるかを決める段階だけ**。
  この結果、`include_private=false` で private な移動例外があると元 slot も移動先も空きになるが、
  これは private 予定を隠すという owner の意図どおりで、単発 private 予定の扱いと同じ。
- **展開量の安全上限（5000）**。ウィンドウ依存の runtime 判定であり、文法判定
  （`rrule_sql_subset`）とは責務を分ける。上限を超えた場合も**切り捨てず**、その master を
  展開せずに `complete=false` を返す。

#### occurrence のレンジ判定は「重なり」（TS / SQL 共通）

繰り返しの occurrence は**点ではなく区間**なので、表示レンジに含まれるかは半開区間の
**重なり**で判定する: `occurrenceStart < rangeEnd && occurrenceEnd > rangeStart`。
開始がレンジ内かどうかでは、レンジ開始前から跨る複数日の予定を落としてしまう。

この判定は `services/occurrences.ts` の `expandEvents`（duration を持つ層）にあり、
単発予定・例外行と**同じ `overlapsRange` を共有**する。`expandRule` が答えるのは「与えられた窓に
入る開始日時」で、レンジ判定そのものには関与しない（ただし Phase 5b-5A 以降、`expandRule` は
候補インデックスを窓から逆算し、`COUNT` を序数の上界として、`UNTIL` を開始日時に対して
適用する）。SQL 側（all-day は `0007`、timed は `0009`）も同じ重なり条件
（`d + duration > from_date`）で実装しており、
**両実装の意味論は一致している**。境界は `occurrences.test.ts` で固定:
レンジ開始前から跨る=含む、`end == rangeStart`=含まない、`start == rangeEnd`=含まない、
完全内包=含む、レンジ全体を覆う=含む。

### `complete` フラグの意味（重要）

`get_free_busy` は `{ complete: boolean, slots: [...] }` を返す。

- busy 算出の対象は、単発予定に加えて **all-day / timed の DAILY・WEEKLY 繰り返し
  （`COUNT` 付きを含む）とその例外行**。`FREQ=MONTHLY` はまだ展開しない。
- ウィンドウに寄与しうる行のうち**1つでも正確に扱えないものがあれば** `complete = false`。
  判断できない入力（未対応の文法、解釈不能な RRULE、展開量が上限超過、例外行の `all_day` が
  親と食い違う、ゾーンを解決できない timed 系列等）はすべて**安全側＝不完全**に倒す。
- `complete = true` が保証するのは「**開示対象の busy をすべて表示した**」であって
  「owner が暇である」ではない。`include_private=false` で除外された private 予定が
  空きに見えるのは owner の意図した挙動であり、この保証には反しない。
- `complete = false` の意味は「**表示されている busy は正しいが、表示されていない時間を
  空きと見なしてはいけない**」。`FreeBusyPage` はこの場合に警告バナーを出す。
- 閲覧画面は次の4状態を厳密に区別する。**取得失敗を空きとして描画することは絶対にない**:
  1. `complete = false` → 不完全である旨の警告バナー＋ busy 表示
  2. RPC 失敗（`22023` やネットワークエラーを含む）→ グリッドを描画せず「取得失敗」表示
  3. `complete = true` かつ `slots = []` → 「この期間に共有されている予定はありません。
     共有リンクが失効または期限切れの場合も同じ表示になります。」という注記を添える
  4. `complete = true` かつ busy あり → Free/Busy 表示

#### `complete = true` / `slots = []` を「空き」と読ませない（重要）

`get_free_busy` は、**失効・期限切れ・不存在のトークン**に対しても、**有効なトークンで owner が
その期間たまたま暇な場合**とまったく同じ `{ complete: true, slots: [] }` を返す。エラーも 404 も
返さない。これは**共有トークンの存在オラクルを作らない**ための設計であり（上記「無効トークンは
エラーにしない」）、変更しない。

結果としてフロントは4者を**区別できず、区別しようともしない**。トークンの状態を見る分岐は
閲覧側のコードに存在しない。一方で、区別できない応答をそのまま全日「—」のグリッドとして
描画すると「この人は全期間空いている」という積極的な主張に見えてしまうため、この場合だけ
上記3の注記を添えて、空きと断定できないようにしている（判定は `freeBusyLayout.ts` の純粋関数
`hasNoDisclosedBusy()`＝`complete` が true かつ `slots.length === 0`、単体テストで固定）。

有効なリンクで owner が本当に暇な週にも同じ注記が出る。これはオラクルを作らないために
意図的に受け入れているコスト。

この注記は本番ブラウザで 2 ケース確認済み（失効リンクで注記が出ること、有効リンクで busy が
ある週は従来どおりで注記が出ないこと）。`complete = false` の警告と RPC 失敗表示は今回変更して
おらず、既存分岐が保たれていることを単体テストと配信バンドルの検査で確認している（実機での
故意の再現は未実施）。

### デプロイ構成（Vercel）

本番: https://timeweave-five.vercel.app（`main` への push で自動デプロイ）

ホスティング設定は **`vercel.json` の 1 ファイルだけ**で、ビルドは Vercel の Vite 自動検出に
任せる（`framework` / `outputDirectory` / `buildCommand` は書かない）。秘密情報は含まない。

- **SPA フォールバック**: `/(.*)` → `/index.html` の rewrite。これが無いと `/s/:token` を
  直接開いたときやリロード時に 404 になる。Vercel は**静的ファイルを rewrite より先に**
  解決するため、この catch-all は `/assets/...` を巻き込まない。リダイレクト（3xx）は使わない:
  ブラウザの URL が書き換わると、パス名からトークンを読む `App.tsx` の分岐が働かなくなる
  （このアプリはルーターライブラリを使わず、`App.tsx` の正規表現 1 本でルーティングしている）。
- **Referrer-Policy**: `Referrer-Policy: no-referrer` を**全レスポンス**に付与する。共有 URL に
  トークンが載るため、`index.html` の `meta` だけでは初期ナビゲーションや一部サブリソースを
  取りこぼしうる。`meta` は多層防御としてそのまま残す。
- **Vercel の Environment Variables**: `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` を
  Production / Preview の両方に登録する。**未設定でもビルドは成功し、認証も共有も無い
  ローカルモードのアプリが無言で公開される**ので、デプロイ後はログインボタンが出ることを
  必ず確認する。`VITE_` 変数はビルド時に埋め込まれるため、後から追加した場合は再デプロイが必要。
- **Supabase 側の設定**: Authentication → URL Configuration の Site URL と Redirect URLs に
  本番 URL を登録する（上記「Supabase セットアップ」参照）。
- SPA catch-all の帰結として、存在しない静的ファイルは 404 ではなく 200 + `index.html` を返す。
  意図的な受容事項（真の 404 が必要になるのは favicon / robots.txt 等を足すとき）。
- `0005` は pgcrypto が `extensions` スキーマにある前提（Supabase 既定）。適用前に
  `select extnamespace::regnamespace from pg_extension where extname='pgcrypto';` で確認する。
