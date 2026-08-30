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
- Phase 5: 共有 URL、Free/Busy、shareToken、RPC による最小データ共有
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
- 共有相手へは `events` を直接公開せず、RPC 経由で `{start, end, status:'busy'}` の
  最小データのみ返す。非公開の予定詳細は DB から出さない。
