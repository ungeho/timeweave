# migration 0025 設計書 — 終日Busyと時刻Availableの共存

**状態: ローカル実装・隔離DB検証まで完了。本番未適用。承認待ち。**

## 実装結果（2026-10-11・隔離DB `timeweave_chain_db`）

```
指紋     wrapper 3a46a5d13e13361744860f7f270f8fbe  変化なし ✓
         core    a9b4097e4b390cee1229709945475d2b  変化なし ✓
         helper  ac87ef25… → 23f069bd792768f9279f5308e3edbaaf  （0025 postflight の新期待値）
ACL      A04 = f|f|f|f 保全 ✓ / A14 = true 保全 ✓（CREATE OR REPLACE が所有者とACLを保持）
新表     owner_settings の anon/PUBLIC 権限 = なし ✓（public スキーマの TRUNCATE 罠を回避）
回帰     0021/0022/0023/0024 の runtime スイートを**無改変で**再実行 → 全PASS
         （0024 は15セクション完走し "RUNTIME SUITE PASSED" を出力＝空振りでない）
E2E      wrapper 経由で 本番P1形状を再現
           ゾーン未設定   → indeterminate（＝本番の現状を正確に再現）
           Asia/Tokyo宣言 → complete / 2件（10-08 09:00-11:00, 10-09 09:00-12:00 +09）
                            10-10 は土曜の終日busyに覆われ正しく除外
アプリ    756 tests PASS / typecheck PASS / build PASS
```

**回帰テストが実装バグを1件捕捉した。** `v_avail_d_frag` をクロスモデル分岐の
内側でしか初期化しておらず、非クロスモデル経路で NULL のままだったため
`v_avail_t_rest + NULL = NULL` となり**時刻availableが全消滅**していた。
R1（時刻busy × 時刻available）が1件→0件で露見。宣言時初期化に修正済み。
この分岐こそ「0024 が既に正しく処理していて、変えてはいけない」側であり、
R系ケースはまさにこれを捕まえるために書かれている。


対象: `timeweave_private.free_busy_available` のクロスモデル判定（0024 セクション6）の解消。

---

## 0. 要約

0024 は、窓の中に「終日 busy」と「時刻あり available」が同時に存在すると
Available 全体を `indeterminate` にする。date と timestamptz の差し引きには
タイムゾーン依存のキャストが必要で、**そのタイムゾーンがどこにも保存されていない**ためである。

本設計の結論は次のとおり。

- **タイムゾーンを持たないまま安全に解消する方法は、実用上存在しない**（§3 で証明）
- **閲覧者のタイムゾーンを窓から逆算する方式は、攻撃者が制御できるため却下**（§4-D）
- **推奨は「オーナーが宣言したタイムゾーン」を新規に保存し、無い場合は現状どおり
  `indeterminate` に倒す方式**（§5 方式C）。既存リンクは挙動不変＝回帰ゼロ

---

## 1. 既存仕様と制約の整理（すべて実装を根拠とする）

### 1-1. 2つの時間モデル

| | 列 | 意味 | 終端 |
|---|---|---|---|
| 時刻あり | `start_at` / `end_at` (`timestamptz`) | UTC instant | exclusive |
| 終日 | `start_date` / `end_date` (`date`) | ローカル暦日 | **exclusive** |

根拠: `src/types/event.ts:54-62`、`supabase/migrations/0001_*.sql` の
`events_time_shape` CHECK。`allDay` で**ちょうど一方だけ**が埋まる。

`events_time_shape` は時刻ありに `end_at >= start_at`（**長さ0を許容**）、
終日に `end_date > start_date` を課す。0024:227-236 がこの非対称性に依存している。

### 1-2. `events.timezone` が持てる行は1種類しかない

```sql
-- 0008_events_timezone.sql:109-112
add constraint events_timezone_placement check (
  timezone is null
  or (all_day = false and rrule is not null and recurrence_id is null)
);
```

**つまり「時刻あり繰り返しマスター」だけがゾーンを持てる。**
終日イベント・時刻あり単発・例外行は、すべて `timezone IS NULL` が強制される。

→ **終日イベントを instant へ変換するためのゾーンは、イベント行には存在しない。**

### 1-3. オーナー単位・リンク単位のタイムゾーンも存在しない

`public` スキーマのテーブルは `events` と `share_links` の2つだけ。
`share_links` に timezone 列は無く、後続 migration でも追加されていない。
プロフィール/設定テーブルも存在しない。

→ **DB のどこにもオーナーのタイムゾーンは無い。**

### 1-4. RPC はタイムゾーンを受け取らない

```sql
-- 0024:745-751
create or replace function public.get_free_busy(
  p_token text, p_from timestamptz, p_to timestamptz,
  p_from_date date, p_to_date date)
```

閲覧者のゾーンは引数に無い。ただし**暗黙には埋め込まれている**（§4-D で詳述）。

### 1-5. クライアント側の窓の作り方（唯一の呼び出し元）

`src/features/share/FreeBusyPage.tsx:61-65` が唯一の呼び出し元。

```ts
const { startIso, endIso } = weekRange(view.anchor, timeZone);
const fromDate = days[0].dayKey;
const toDate   = addDaysToDateString(days[6].dayKey, 1);
```

`weekRange`（`weekGrid.ts:53-59`）と `buildWeekDays`（同 40-44）は
**同じ `weekStartDayKey(anchor, timeZone)`** を起点とするため、
instant 窓と date 窓は常に同一週を指す。さらに

```ts
dayStartInstantIso(dayKey, tz) = fromZonedTime(`${dayKey}T00:00:00`, tz)
```

（`src/utils/timezone.ts:36-38`）なので、**契約として**

```
p_from = 閲覧者ゾーンにおける p_from_date のローカル深夜0時の instant
p_to   = 閲覧者ゾーンにおける p_to_date   のローカル深夜0時の instant
```

が成り立つ。**これはクライアントの実装上の性質であって、サーバは検証していない。**

### 1-6. 完全性判定の既存契約

- 0021 の3分岐は `availability = 'busy'` で鍵付けされ、Busy の `complete` を決める
- 0024 の A'/B'/C'/D' は同じ構造を `availability = 'available'` で鍵付けし、
  Available 側の完全性を独立に決める
- **Busy の `complete` と Available の完全性は独立**。一方が他方を代弁しない

### 1-7. 0024 が既に持っているゾーン情報

0024:300-311 は、オーナーの**時刻あり繰り返しマスター**の `timezone` を集めて
`v_tz_all` とし、`public.timezone_is_resolvable()` を通したものを `v_ok_tz` とする。
これは展開可否の判定にのみ使われる。§5 方式B の材料になる。

検証関数は 0008 が2つ提供している。

- `public.timezone_is_supported(text)` — 値の妥当性（長さ・字形・禁止名・カタログ所属）
- `public.timezone_is_resolvable(text)` — このサーバで解決できるか

---

## 2. 現象の確定（本番実測・2026-10-11）

```
リクエスト  p_from 2026-10-04T15:00:00Z / p_to 2026-10-11T15:00:00Z
            p_from_date 2026-10-05 / p_to_date 2026-10-12  （閲覧者 UTC+9）
レスポンス  link_state=active, complete=true, slots=3,
            available={"status":"indeterminate"}
```

オーナーの該当週: 終日busy 2件 / 時刻busy 1件 / 時刻available 3件。

隔離DBの対照実験（公開RPC経由・全 rollback）:

| | データ | 結果 |
|---|---|---|
| P1 | 本番と同形状 | `indeterminate` |
| P2 | **終日busyだけ**除去 | `complete` / available 3件 |
| P3 | available も終日にしてモデルを揃える | `complete` / available 1件 |

変数は「終日busyの有無」ただ1つ。原因は 0024:675-682 で確定。

---

## 3. なぜ「ゾーン無しの安全な変換」が成立しないか

終日イベント「日付 D」が指す instant 区間は、ゾーン次第で動く。
地球上のオフセットは概ね **UTC−12 〜 UTC+14**（26時間幅）。

- **和（最大包絡）**: `[D 00:00 +14, D+1 00:00 −12]` = **50時間**
  安全（必ず真の区間を含む）だが、終日busy 1件が前後の日の available も消す
- **積（最小包絡）**: 24時間の日を26時間幅でずらすため **空集合**
  → 何も差し引かない＝**過剰開示**。原則2に反する

> **結論**: ゾーンを決めずに「安全かつ実用的」な変換は存在しない。
> 安全side に倒せば実用性が消え、実用side に倒せば原則2を破る。
> **タイムゾーンの決定が本設計の本体である。**

---

## 4. 4ケースの個別検討

### A. 終日Busy × 時刻Available（本番で発生中）

終日busy を instant 区間へ変換し、`v_avail_t` から差し引く。**ゾーンが必要。**

### B. 時刻Busy × 終日Available

指示は「時刻Busyが存在する日を終日Availableとして公開してはいけない」。
実装案は2つ。

- **B-1（保守・単純）**: 時刻busy が1分でも触れる日を、終日available 集合から
  **日単位で丸ごと除去**。instant→date の写像にゾーンが必要
- **B-2（精密）**: 終日available を instant へ展開して差し引き、
  残りを**時刻スロットとして出力**。「終日」は出さないので指示を満たし、
  利用価値も残る。ただし出力形状が all-day から timed に変わる

**推奨は B-2。** 指示が禁じているのは「その日を終日availableとして公開すること」で
あり、残余を時刻スロットで出すことは禁じていない。B-1 は1分の重なりで
24時間を失うため、実用上ほぼ B-2 が必要になる。
（ゾーンが無い場合は両者とも不可 → fail-closed）

### C. 終日Busy × 終日Available

現状どおり `datemultirange` 同士で処理。**変更不要**（0024:695 の `v_avail_d - v_busy_d`）。

### D. 時刻Busy × 時刻Available

現状どおり `tstzmultirange` 同士。**変更不要**（0024:696）。

---

## 5. タイムゾーン決定モデルの比較

### 方式A: 閲覧者のタイムゾーン（窓から逆算）

§1-5 の契約から `offset = p_from_date::timestamp - p_from` で導出できる。
**スキーマ変更不要**という利点がある。

**却下する。** 理由は2つ。

1. **攻撃者が制御できる。** 引数はすべてクライアント供給で、サーバは
   §1-5 の関係を検証していない。攻撃者が任意のオフセットを主張すると、
   終日busy の変換先をずらして available を**過剰開示**させられる。
   原則2（Busyの可能性が残る時間を公開しない）に正面から反する
2. **意味論が誤り。** 終日イベントは「オーナーの暦日」であって
   閲覧者の暦日ではない。閲覧者が移動するたびに意味が変わるのは不正

### 方式B: オーナーの既存マスターから推定（`v_ok_tz`）

0024 が既に持つ `v_ok_tz` が**ちょうど1つ**のゾーンに収束する場合に限り、それを採用。
複数・空なら fail-closed。**スキーマ変更不要。**

**採用しない（候補としては残す）。** オーナーが「自分の終日イベントはこのゾーン」と
**宣言していない**ため、これは推定である。外れた場合の誤差は最大26時間で、
その分だけ過剰開示が起きうる。原則「安全性が証明できない変換を採用しない」に照らすと、
主方式にはできない。

なお本番オーナーは `Asia/Tokyo` の時刻あり繰り返しマスターを1件持つため、
この方式なら**即座に動く**。短期の暫定措置としては検討の余地がある。

### 方式C: オーナーが宣言したタイムゾーンを保存（**推奨**）

新しい保存先を1つ追加し、オーナーが明示的に設定する。
**未設定なら現状どおり `indeterminate`** に倒す。

- 意味論が正しい（終日＝オーナーの暦日）
- 攻撃者が制御できない（サーバ側の保存値）
- **既存リンクは未設定なので挙動不変＝回帰ゼロ**。opt-in の改善になる
- `public.timezone_is_supported()`（0008）で値を検証でき、新しい検証ロジックが不要

**保存先の選択（未決定・§9）**

| 案 | 置き場 | 長所 | 短所 |
|---|---|---|---|
| C-1 | `public.share_links.timezone`（nullable） | helper が既にこの行を読んでいる（0024:282-288）。追加の join 不要。最小変更 | リンクごとに別ゾーンを持てる＝同じイベントの意味がリンクで変わる（意味論の破れ・footgun） |
| C-2 | 新表 `public.owner_settings(owner_id pk, timezone)` | 1オーナー1真実。意味論が正しい | 新表・RLS・UI が必要。helper に join が1つ増える |

**推奨は C-2。** C-1 は最小変更だが、「終日の意味がリンクごとに変わる」は
後から直せない設計上の誤りになる。

### 方式D: UTC 固定 / サーバセッションの TimeZone

**明示的に却下。** 指示にもあるとおり暗黙依存であり、
0024 が `set search_path = ''` と「no timezone read」で避けてきた性質そのもの。

---

## 6. fail-closed 条件の定義

以下のいずれかに該当したら、**従来どおり `indeterminate` を返す**（Available のみ。
Busy の答えは一切変えない）。

1. クロスモデルが発生している（`v_avail_t` と `v_busy_d` の両方が非空、
   またはその逆）**かつ** 基準タイムゾーンが決定できない
2. 基準タイムゾーンが `public.timezone_is_resolvable()` を通らない
3. 基準タイムゾーンが `public.timezone_is_supported()` を通らない（保存値の破損）
4. 変換中に `invalid_datetime_format` / `datetime_field_overflow` /
   `invalid_text_representation` が発生（0024:270-273 と同じ扱い）
5. Busy ハンドオフが不正（0024 セクション2・2b・2c の既存条件。**変更しない**）
6. Available 側の完全性が崩れている（0024 セクション4・4b の A'/B'/C'/D'。**変更しない**）

> 1 が重要。**クロスモデルが起きていないケースでは、ゾーンが無くても従来どおり
> 正常に動く。** ゾーンを要求するのはクロスモデルが実際に発生した窓だけに限定する。

---

## 7. SQL 変更予定箇所

**0022〜0024 および凍結SQLテストは一切編集しない。** 0025 を新規追加する。

```
supabase/migrations/0025_freebusy_crossmodel.sql   新規

  1. （方式C-2 の場合）public.owner_settings 新表
     - owner_id uuid primary key default auth.uid()
     - timezone text not null check (public.timezone_is_supported(timezone))
     - RLS: 自分の行のみ select/insert/update
     - 匿名には非公開（helper は definer 経由で読む）

  2. create or replace function timeweave_private.free_busy_available(...)
     - 同一シグネチャで置換（CREATE OR REPLACE は所有者とACLを保持する）
     - セクション6 を「ゾーンがあれば変換して差し引く／無ければ c_indet」に差し替え
     - セクション1〜5・7 は無変更

  3. public.get_free_busy は無変更
     - レスポンス形式・Busy の slots/complete・3状態すべて維持
     - 0024 の wrapper をそのまま使う（B01 指紋は変わらない）
```

**アプリ側の変更（0025 とは別コミット）**

```
src/types/share.ts            変更不要（AvailableResult は3状態のまま）
src/repositories/shareRepository.ts  変更不要
src/features/share/FreeBusyPage.tsx  変更不要
src/features/share/ShareDialog.tsx   タイムゾーン設定UIを追加（方式C採用時）
src/repositories/...          owner_settings の読み書き（方式C-2採用時）
```

**Available のスロット形状が変わる点に注意（B-2 採用時）**: 終日available が
時刻busy で削られると timed スロットとして出る。`FreeBusySlot` は両形状を
表現できるので型変更は不要だが、表示テストは追加する。

---

## 8. テストマトリクス

隔離DB（`timeweave_chain_db`）で公開RPC経由、すべて rollback。

### 8-1. 既存の回帰（挙動が変わらないこと）

| # | ケース | 期待 |
|---|---|---|
| R1 | 時刻busy × 時刻available | 現状と同一（差分なし） |
| R2 | 終日busy × 終日available | 現状と同一 |
| R3 | available 0件 | `complete` / 0件 |
| R4 | `share_available=false` | `not_requested` |
| R5 | 失効・期限切れ・不正トークン | `unavailable`、available キー無し |
| R6 | Busy `complete=false` | `indeterminate`（セクション2は無変更） |
| R7 | 展開不能な available マスター | `indeterminate`（セクション4は無変更） |
| R8 | ゾーン未設定 ＋ クロスモデル | `indeterminate`（＝0024 と同じ） |
| R9 | ゾーン未設定 ＋ クロスモデル無し | `complete`（**ゾーンを要求しない**） |

### 8-2. 新規（クロスモデル解消）

| # | ケース | 期待 |
|---|---|---|
| X1 | 終日busy × 時刻available（本番 P1 形状） | `complete`、終日busy の当日分だけ差し引かれる |
| X2 | 時刻busy × 終日available、1分だけ重なる | その日は終日として出ない（B-2 なら残余が timed） |
| X3 | 時刻busy が日付をまたぐ（23:00–01:00） | 2日とも正しく削られる |
| X4 | 終日busy が週境界をまたぐ | 窓内の部分だけ差し引かれる |
| X5 | DST 開始日（23時間の日） | 終日 = 23時間として変換される |
| X6 | DST 終了日（25時間の日） | 終日 = 25時間として変換される |
| X7 | ローカル深夜0時が存在しない日（spring-forward が 00:00 のゾーン） | fail-closed または明示的な解決規則に従う（§9 未決） |
| X8 | 閲覧者ゾーン ≠ オーナーゾーン | **オーナーゾーン**基準で変換される |
| X9 | 保存ゾーンが解決不能 | `indeterminate` |
| X10 | 保存ゾーンが破損値 | `indeterminate`（CHECK を通り抜けた場合の保険） |
| X11 | 重複する終日busy | `range_agg` で正規化され二重差し引きなし |
| X12 | available が busy で2分割される | 2スロット |
| X13 | private + available、`include_private=true` | 開示される |
| X14 | private + available、`include_private=false` | 除外される |
| X15 | 繰り返し available × 終日busy | 展開後に差し引かれる |
| X16 | 例外行（available マスターの1回だけ busy） | 当該回のみ除外 |
| X17 | 同一入力の2回呼び出し | 同一結果 |

### 8-3. セキュリティ

| # | ケース | 期待 |
|---|---|---|
| S1 | 窓の instant と date を**意図的にずらして**送る | 結果が保存ゾーンのみに依存し、窓の細工で available が増えない |
| S2 | 極端なオフセットを示唆する窓 | 同上 |
| S3 | helper への直接 EXECUTE | 0024 と同じく revoke 済み（A04） |
| S4 | wrapper 所有者からの helper 実行 | 可能（A14） |

**S1/S2 は方式A を却下した根拠そのものなので、回帰テストとして必ず入れる。**

---

## 9. 互換性・セキュリティ上のリスク

| リスク | 評価 | 緩和 |
|---|---|---|
| 既存リンクの挙動変化 | **なし**。ゾーン未設定なら 0024 と同一 | R8/R9 で固定 |
| 過剰開示（本質的リスク） | ゾーンが誤っていれば最大26時間ずれる | 宣言方式＋`timezone_is_supported` 検証＋未設定 fail-closed |
| 窓細工による操作 | 方式C では窓はゾーン決定に関与しない | S1/S2 |
| Busy 契約の破壊 | セクション1〜5 を触らないため影響なし | R1-R7 |
| 指紋の変化 | helper の md5 は変わる（B02）。wrapper/core は不変 | 0025 の postflight で新しい期待値を定義 |
| `CREATE OR REPLACE` の所有者/ACL | 保持される（実測済み） | postflight A04/A14 を再実行 |
| 新表の権限 | `public` スキーマの新表は anon に TRUNCATE が付く既知の罠 | 明示 REVOKE、または `timeweave_private` に置く |

最後の行は既知の実測事項であり、0025 の preflight/postflight に必ず含めること。

---

## 10. 実装手順とロールバック方針

### 手順

1. 0025 を書く（新表 → helper 置換の順。1トランザクション）
2. 隔離DB `timeweave_chain_db` で 0001→0025 のフルチェーンを通す
3. §8 のマトリクスを隔離DBで全件実行
4. 既存の 0021/0022/0023/0024 の runtime テストを**無改変で**再実行（回帰確認）
5. 本番 preflight（適用前の指紋・ACL・行数を記録）
6. 本番適用
7. 本番 postflight（helper の新指紋、A04/A14/W05 の保全、Busy 契約の不変）
8. アプリ側（UI）は**別コミット・別デプロイ**

### ロールバック

helper は `CREATE OR REPLACE` なので、**0024 の helper 本文をそのまま再適用すれば
即座に戻る**（所有者と ACL は保持される）。新表は残しても無害
（未参照になるだけ）。したがって

```
ロールバック = 0024 の free_busy_available を create or replace で再適用
             + （任意）owner_settings を drop
```

**wrapper と core は触らないため、ロールバック時も Busy 共有は一切影響を受けない。**
この分離が本設計の安全性の中心である。

---

## 11. 未決定事項と推奨判断

| # | 論点 | 推奨 | 理由 |
|---|---|---|---|
| U1 | 保存先（C-1 リンク / C-2 オーナー） | **C-2** | 終日の意味がリンクで変わる設計は後から直せない |
| U2 | ケースB の扱い（B-1 日単位除去 / B-2 精密差し引き） | **B-2** | 1分の重なりで24時間を失うのは実用に耐えない。指示の禁止事項は満たす |
| U3 | ローカル深夜0時が存在しない日（X7） | **fail-closed** | 解決規則を発明するより、その窓だけ indeterminate にする方が原則3に忠実 |
| U4 | 方式B（推定）を暫定措置として入れるか | **入れない** | 証明できない変換。ただし本番オーナーは即日動くので、判断はユーザーに委ねる |
| U5 | UI でのタイムゾーン設定場所 | ShareDialog か設定画面か | 0025 の DB 部分とは独立に決めてよい |
| U6 | 既存オーナーへの既定値 | **設定しない（NULL）** | 推測で入れると過剰開示になる。明示設定を促す |

---

## 13. ユーザー設定（タイムゾーン / 表示言語）

### 13-1. 2つの設定は役割が根本的に違う

| | タイムゾーン | 表示言語 |
|---|---|---|
| 誰のものか | **オーナー**（終日イベントの意味を決める） | **見ている人**（画面の文言） |
| Free/Busy の計算に影響するか | **する**（§5 方式C の中核） | **しない** |
| 匿名共有ページでの扱い | **オーナーの設定**を使う（閲覧者のゾーンは使わない） | **閲覧者のブラウザ**に従う（オーナーの設定は使わない） |
| 未設定時 | クロスモデル時のみ fail-closed | ブラウザ既定にフォールバック |

**この表の2列目と3列目が逆転しないことが、設計上もっとも重要な点である。**
閲覧者のゾーンで終日イベントを解釈すると §5 方式A の攻撃が成立し、
オーナーの言語で匿名ページを描くと見知らぬ訪問者に読めない画面が出る。

**閲覧者のタイムゾーンは表示専用**（週グリッドの日付境界・時刻の整形）であり、
現在も `FreeBusyPage` がその用途にのみ使っている。0025 でもこの役割は変えない。

### 13-2. 保存先

U1 の決定どおりオーナー単位。1つの新表に**両方の列**を置く。

```sql
public.owner_settings
  owner_id   uuid primary key default auth.uid()   -- events と同じ流儀（FKは張らない）
  timezone   text   null                           -- IANA 名。NULL = 未設定
  language   text   null                           -- 'ja' | 'en'。NULL = ブラウザ既定
  created_at timestamptz not null default now()
  updated_at timestamptz not null default now()
```

- `events.owner_id` は FK を持たず `auth.uid()` 既定のみなので、**同じ流儀に合わせる**
  （`auth.users` は環境によって shim であり、FK を張ると隔離DBで壊れる）
- **`language` の列は 0025 の SQL からは一切読まれない。** Free/Busy の計算に
  言語が混入しないことを、参照ゼロという形で構造的に保証する

### 13-3. 値の検証 — CHECK ではなく trigger

`public.timezone_is_supported()` は **STABLE であって IMMUTABLE ではない**
（`pg_timezone_names` を読むため）。したがって **CHECK 制約には使えない**。
0008 が `events` に対して採った方式と同じく、**トリガで検証する**。

```
timezone  trigger で public.timezone_is_supported() を通す
          違反は 0008 と同じ DETAIL = 'TIMEWEAVE_TZ_INVALID'
language  CHECK (language is null or language in ('ja','en'))
          不変の集合なので CHECK で足りる
```

### 13-4. 権限

`public` スキーマの新表は **anon に TRUNCATE が付く既知の罠**がある（実測済み）。
明示的に落とす。

```
revoke all on public.owner_settings from public, anon;
grant select, insert, update on public.owner_settings to authenticated;
RLS: owner_id = auth.uid() の行のみ
```

匿名は自分でこの表を読めない。helper は SECURITY DEFINER wrapper の
配下で動くため読める（0024 が `share_links` を読んでいるのと同じ経路）。

### 13-5. タイムゾーン変更時の UI 説明（必須）

ゾーンの変更は**過去のイベントの意味を遡って変える**。終日イベントは
「オーナーの暦日」なので、ゾーンを変えると匿名共有に出る instant がずれる。
設定画面で次を明示する。

- 終日予定の解釈が変わること
- 匿名共有ページの空き時間表示が変わりうること
- 時刻ありの予定（`start_at`）は absolute なので**変わらない**こと

---

## 14. 0025 と多言語対応の実装境界

### 14-1. 結論：**分離する**

言語切り替えは 0025 に含めない。**DB の列だけ 0025 で用意し、
UI の翻訳基盤は別 Phase（0026 相当のアプリ専用作業）とする。**

### 14-2. 判断根拠

| 観点 | タイムゾーン（0025） | 言語（別Phase） |
|---|---|---|
| 変更範囲 | SQL 1関数 + 新表1つ + 設定UI1画面 | **ほぼ全コンポーネント**（文言の抽出・置換） |
| 失敗したときの被害 | **過剰開示**（セキュリティ） | 文言が英語/日本語のまま（表示のみ） |
| ロールバック | helper を 0024 本文で `create or replace` | コード revert |
| テストの性質 | DB の正しさ（隔離DBのマトリクス） | 文言の網羅性（未翻訳検出） |
| 匿名ページへの影響 | 計算結果が変わる | 文言のみ |

**混ぜるべきでない理由は「差分の大きさ」ではなく「失敗の種類が違う」こと。**
0025 はセキュリティ境界の変更で、レビューは「過剰開示が起きないか」に
集中させる必要がある。数百箇所の文言差分が同じコミットにあると、
その集中が物理的に不可能になる。ロールバック単位も揃わない。

### 14-3. 分離した場合の依存関係

```
0025（DB + タイムゾーンUI）
  └─ owner_settings.language 列だけ先に作っておく
       └─ 言語Phase（アプリのみ・DB変更なし）
            - i18n 基盤（辞書・切替・フォールバック）
            - カレンダー / 共有ページ / 設定画面の文言
            - 未翻訳検出テスト
```

列を先に作るため、言語Phase は **DB migration を一切伴わない純粋なアプリ作業**に
なる。これが分離の実利である。

### 14-4. 言語Phase の留意点（設計メモ・実装は別途）

- **匿名共有ページの言語はオーナー設定ではなく閲覧者のブラウザに従う**
  （`navigator.language`）。オーナーの `language` 列は認証済み画面専用
- 既存の日本語文言は `freeBusyPresentation.ts` / `availablePresentation.ts` /
  `errors.ts` など**純粋モジュールに集約済み**で、ここが翻訳の足がかりになる
- `eventTitle.ts` の `eventDisplayTitle` は既に「1つの map に置き、将来の
  ja/en 切替はここだけ」という前提で書かれている
- 未翻訳検出は、辞書のキー集合と使用箇所の突き合わせを単体テストで行う
  （コンポーネントテストは環境上不可）

---

## 12. 当面の回避策（0025 を待たずに可能）

コード変更不要。

- 共有する週から**終日 busy を外す**
- または **available も終日で登録**してモデルを揃える（P3 で実証済み）

本番オーナーは週次の終日 busy（境界テスト）を持つため、
現状のままでは毎週 `indeterminate` になる。
