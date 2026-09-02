# TimeWeave

個人用スケジューラー兼・空き時間共有 Web アプリ。React + TypeScript + Vite。

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
3. Authentication → Providers で **Google** を有効化し、Google Cloud の OAuth
   クライアント ID / Secret を設定。Authorized redirect に Supabase のコールバック URL、
   アプリ側 Redirect URL に `http://localhost:5173`（開発）と本番 URL を登録。

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
- **Phase 5a（実装済み・実DB／実ブラウザ検証済み・未デプロイ）**: 共有 URL（`/s/:token`）と
  匿名 Free/Busy 表示。
  `share_links` テーブル（`0004`）とマイグレーション `0005` の SECURITY DEFINER RPC 4本
  （`create_share_link` / `list_share_links` / `revoke_share_link` / `get_free_busy`）で構成。
  カレンダー右上「共有」ボタン（Supabaseモード時のみ表示）から `ShareDialog` で
  作成 / 一覧 / 失効 / URLコピーができ、`include_private` と `expires_at` を作成時に指定する。
  閲覧側 `FreeBusyPage` は `AuthGate` の外側でレンダリングされ、週送り以外の操作を持たない
  完全な読み取り専用。詳細は下記「共有のセキュリティ境界（Phase 5a）」。
- **Phase 5b-0（実装済み・実DB検証済み）**: SQL 側 RRULE パーサ（`0006`）。展開はまだ行わず、
  「UNTIL から終了済みと証明できる series」を completeness 判定から除外する narrowing のみ。
- **Phase 5b-1（実装済み・DB未適用）**: all-day の `FREQ=DAILY` / `FREQ=WEEKLY` を
  Free/Busy へ展開（`0007`）。例外行とキャンセルも解決する。詳細は下記
  「繰り返しの Free/Busy 展開（Phase 5b-1）」。
- Phase 5b-2 以降（未着手）: `events.timezone` の追加と timed 繰り返しの展開、`COUNT`、
  `FREQ=MONTHLY`。いずれも現状は `complete=false` に倒している。
- Phase 6: ドラッグ&ドロップ、レスポンシブ改善、ダークモード仕上げ

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
  `<meta name="referrer" content="no-referrer">` を置き Referer 経由の漏洩を防ぐ。

### 繰り返しの Free/Busy 展開（Phase 5b-1）

匿名 Free/Busy で展開するのは **all-day の `FREQ=DAILY` / `FREQ=WEEKLY`** のみ
（`INTERVAL`、`BYDAY`(WEEKLY限定)、DATE 形式 `UNTIL` に対応）。
`COUNT` / `FREQ=MONTHLY` / timed 繰り返しは未対応で、`complete=false` に倒す。

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
単発予定・例外行と**同じ `overlapsRange` を共有**する。`expandRule` は「与えられた窓に
入る開始日時」だけを答える責務のままで、RRULE の意味論（COUNT / UNTIL / 打ち切り）には
触れていない。SQL 側（`0007`）も同じ重なり条件（`d + duration > from_date`）で実装しており、
**両実装の意味論は一致している**。境界は `occurrences.test.ts` で固定:
レンジ開始前から跨る=含む、`end == rangeStart`=含まない、`start == rangeEnd`=含まない、
完全内包=含む、レンジ全体を覆う=含む。

### `complete` フラグの意味（重要）

`get_free_busy` は `{ complete: boolean, slots: [...] }` を返す。

- busy 算出の対象は、単発予定に加えて **all-day の DAILY / WEEKLY 繰り返しとその例外行**
  （Phase 5b-1）。timed 繰り返し・`COUNT`・`FREQ=MONTHLY` はまだ展開しない。
- ウィンドウに寄与しうる行のうち**1つでも正確に扱えないものがあれば** `complete = false`。
  判断できない入力（未対応の文法、解釈不能な RRULE、展開量が上限超過、例外行の `all_day` が
  親と食い違う等）はすべて**安全側＝不完全**に倒す。
- `complete = true` が保証するのは「**開示対象の busy をすべて表示した**」であって
  「owner が暇である」ではない。`include_private=false` で除外された private 予定が
  空きに見えるのは owner の意図した挙動であり、この保証には反しない。
- `complete = false` の意味は「**表示されている busy は正しいが、表示されていない時間を
  空きと見なしてはいけない**」。`FreeBusyPage` はこの場合に警告バナーを出す。
- 閲覧画面は次の3状態を厳密に区別する。**取得失敗を空きとして描画することは絶対にない**:
  1. `complete = false` → 不完全である旨の警告バナー＋ busy 表示
  2. RPC 失敗（`22023` やネットワークエラーを含む）→ グリッドを描画せず「取得失敗」表示
  3. 正常成功 → Free/Busy 表示

### デプロイ時 TODO（未対応・デプロイ先未確定のため保留）

- **SPA フォールバック**: `/s/:token` は Vite dev では index.html にフォールバックするが、
  本番ホスティングには rewrite 設定が必要（未追加）。無いと共有 URL が 404 になる。
- **Referrer-Policy を HTTP ヘッダでも送出**: 現状は `index.html` の `meta` のみ。
  meta は初期ナビゲーションや一部サブリソースを取りこぼしうるため、ホスティング側で
  `Referrer-Policy: no-referrer` ヘッダも設定する。
- `0005` は pgcrypto が `extensions` スキーマにある前提（Supabase 既定）。適用前に
  `select extnamespace::regnamespace from pg_extension where extname='pgcrypto';` で確認する。
