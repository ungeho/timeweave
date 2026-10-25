/**
 * The Japanese dictionary, and the DEFINITION OF THE KEY SET.
 *
 * Every other dictionary is typed against this one, so adding a key here is
 * what makes it required everywhere else. `as const` is load-bearing twice
 * over: it fixes the key set, and it preserves each message's literal type so
 * `ExtractVars` can read the placeholders out of it.
 *
 * KEY NAMING. `area.thing`, lower camel after the dot. The area is where the
 * string is SHOWN, not which module happens to hold it today -- P3 moves these
 * strings out of components, and a key named after a file would be wrong the
 * moment the file is split.
 *
 * WHAT IS IN HERE SO FAR. P1 wires nothing up; this is a seed chosen to
 * exercise the design rather than to be complete:
 *   - messages with no placeholders,
 *   - one placeholder,
 *   - several placeholders,
 *   - and one that must NOT drift in meaning when translated (the Available
 *     indeterminate notice), so the parity tests have a real subject.
 * P3 grows this to the ~200 strings the survey counted, module by module.
 */

export const ja = {
  // --- common ---------------------------------------------------------
  'common.save': '保存',
  'common.cancel': 'キャンセル',
  'common.close': '閉じる',
  'common.delete': '削除',
  'common.saving': '保存中…',
  'common.loading': '読み込み中…',

  // --- settings -------------------------------------------------------
  'settings.title': '設定',
  'settings.signedInAs': 'ログイン中',
  'settings.timezone.label': 'タイムゾーン',
  'settings.language.label': '表示言語',
  'settings.language.followBrowser': 'ブラウザの設定に従う',
  'settings.saved': '設定を保存しました。',
  // The zone field's own hint. Says what the zone DECIDES (which calendar day
  // an all-day event falls on) and what clearing it does, because an empty
  // field here is a real state -- not-set -- and not a missing value.
  'settings.timezone.hint':
    '終日の予定をどの暦日として扱うかを決めます。空欄にすると未設定に戻ります。',

  // The confirmation step before a zone change. It is a confirmation, not a
  // warning about failure: the change is safe, it just reinterprets every
  // all-day event, and TIMEZONE_CHANGE_NOTICE lists what that means.
  'settings.timezone.confirmTitle': 'タイムゾーンを変更します。',
  'settings.timezone.confirmApply': '変更する',

  // --- share ----------------------------------------------------------
  'share.label.count': '{count} / {max}',
  // The ceiling travels as a variable, so the sentence cannot drift from
  // SHARE_LABEL_MAX -- the same arrangement content.*TooLong uses.
  'share.label.tooLong': 'ラベルは{max}文字以内で入力してください',
  'share.link.status': '{label} — {status}',

  /**
   * Said when the backend could not determine open time exactly.
   *
   * MUST NOT become "there is no open time" in any language. It reports an
   * absence of knowledge, not an absence of availability, and a viewer acts on
   * the difference. The en parity test asserts the negative form explicitly.
   */
  'share.available.indeterminate':
    '空き時間を正確に判定できませんでした。この期間については、空いているかどうかを確認するには直接ご連絡ください。',

  /** An exact computation that disclosed nothing. "Shared", never "has". */
  'share.available.empty': 'この期間に共有されている空き時間はありません。',

  // What a catch shows when the thrown value was not an Error at all. Said in
  // words rather than String(cause), which would put "undefined" or
  // "[object Object]" on screen -- and, for an arbitrary thrown object, an
  // unbounded stringification of whatever it happens to carry. Not namespaced
  // to one screen: every catch site in the app renders this one sentence.
  'error.unknownCause': '原因を特定できませんでした',

  // --- errors ---------------------------------------------------------
  //
  // The wording is EXACTLY what the Error classes produced before P3. Each
  // class now carries a key instead of building its own sentence, and the
  // message it reports is this entry rendered in Japanese -- so `.message` is
  // byte-identical and every existing catch site keeps working unchanged.
  'error.retry.wait': 'しばらく待ってからもう一度お試しください',
  'error.retry.seconds': '約{seconds}秒後にもう一度お試しください',
  'error.retry.minutes': '約{minutes}分後にもう一度お試しください',

  'error.duplicateException': 'この繰り返し予定の回には、すでに個別の変更が存在します',
  'error.seriesEditBlocked': '個別に変更した回があるため、繰り返し全体の変更はできません',
  'error.writeRateLimited': '保存が短時間に集中したため、一時的に制限しています。{advice}',
  'error.freeBusyRateLimited': '空き時間の取得が短時間に集中したため、一時的に制限しています。{advice}',
  'error.freeBusyBusy': '空き時間の計算が混み合っています。{advice}',
  'error.shareLinkRateLimited': '共有リンクの作成が短時間に集中したため、一時的に制限しています。{advice}',
  'error.shareLinkActiveQuota': '有効な共有リンクの数が上限に達しました。不要なリンクを失効させてから、もう一度お試しください',
  'error.shareLinkTotalQuota': '共有リンクの総数が上限に達しました。失効済みのリンクを削除すると枠が空きます（失効させるだけでは総数は減りません）。失効済みがなければ、不要なリンクを先に失効させてください',
  'error.recurrenceGraph': '予定を保存できませんでした。操作をやり直してください。',
  'error.eventQuota': '保存できる予定の上限に達しました。不要な予定を削除してから、もう一度お試しください',
  'error.exceptionQuota': 'この繰り返し予定の個別変更が上限に達しました。個別変更を整理してから、もう一度お試しください',
  'error.invalidTimezone': 'このタイムゾーンは使用できません。ブラウザの日付と時刻の設定をご確認ください',
  'error.timezoneRequired': '繰り返し予定のタイムゾーンを決定できなかったため、保存できませんでした',
  'error.timezoneCleared': '繰り返し予定のタイムゾーンは解除できません',

  // TWO MORE SPECIFIC WORDINGS FOR EXISTING CODES, not new failures.
  //
  // Both were explicit Japanese strings passed to a constructor, which
  // hasCustomMessage returns verbatim -- so they would have stayed Japanese
  // after P6. They are keys now, and the classes pick between the generic and
  // the specific wording by `reason`; the `code` stays single, exactly as
  // FreeBusy's two kinds share one code.
  //
  // 'error.timezonePlacement' is raised from TWO places with the identical
  // sentence (recurrenceOps and eventRepository), which is why it is one key
  // rather than two.
  'error.timezonePlacement': 'タイムゾーンを持てるのは時刻ありの繰り返し予定だけです',
  'error.seriesTimezoneBlocked':
    '個別に変更した回があるため、繰り返しのタイムゾーンは変更できません',

  // --- share page (pure presentation modules) --------------------------
  //
  // THREE OF THESE CARRY SAFETY MEANING, and the tests that guard them assert
  // what they must NOT say. Translating them is not substitution:
  //   unavailable       names no reason -- expired, revoked, deleted, unknown
  //                     and malformed all arrive as one state (0023).
  //   activeEmpty       says nothing is SHARED for the period, not that the
  //                     owner is free.
  //   errorNotFree      the clause that stops an error screen being read as
  //                     "no events".
  'share.unavailable': 'この共有リンクは利用できません。',
  'share.activeEmpty': 'この期間に共有されている予定はありません。',
  'share.error.generic': '空き時間を取得できませんでした。時間をおいて再読み込みしてください。',
  'share.error.notFreeNote': '（この画面は「予定なし」を意味しません）',

  // --- share page (anonymous viewer) -----------------------------------
  //
  // The viewer here has no session, so these render in THEIR browser's
  // language, never the owner's. The owner's preference is not even fetched
  // on this route (LanguageProvider isPublicRoute).
  // P8-mobile-2: was 空き時間（読み取り専用）, which named only the part a
  // busy-only link never shows. The page is the owner's free/busy.
  'sharePage.subtitle': '予定の空き状況（読み取り専用）',
  'sharePage.disabled': '共有機能は利用できません。',
  'sharePage.thisWeek': '今週',
  'sharePage.prevWeek': '前の週',
  'sharePage.nextWeek': '次の週',
  'sharePage.loading': '読み込み中…',
  'sharePage.incompleteWarning':
    'この期間には未対応の繰り返し予定が含まれています。表示されていない時間も空いているとは限りません。',
  'sharePage.block.busyAllDay': '終日 予定あり',
  'sharePage.block.busy': '予定あり',
  'sharePage.block.availableAllDay': '終日 空き時間',
  // The ACCESSIBLE NAME of a timed block. The visible text is the range alone
  // ("09:00–09:30"); the state is carried by colour and shape, which a screen
  // reader cannot see. Composed from the two labels above rather than
  // repeating them, so "busy must not read as open" keeps holding here too.
  'sharePage.block.timeRange': '{state}、{start}から{end}',
  'sharePage.block.available': '空き時間',
  // Read out for a day on which nothing is drawn; the dash is decorative.
  'sharePage.day.nothing': '表示なし',
  // The footer changes when open time is on screen, because the shorter
  // sentence stops being true the moment an available block is drawn.
  'sharePage.footer.busyOnly': '表示されるのは予定の有無（busy）のみで、内容は共有されません。',
  'sharePage.footer.withAvailable':
    '表示されるのは予定の有無（busy）と、共有者が明示した空き時間（available）だけで、内容は共有されません。空き時間として表示されていない時間が空いているとは限りません。',

  // --- share page legend (shown since P8-mobile-2) -----------------------
  //
  // Prepared for a later phase. The wording states the DISTINCTION rather
  // than naming a colour, because the visual contract is not hue: busy is a
  // filled --accent bar, available is the page surface inside an --accent
  // outline PLUS a 45-degree hatch (styles/global.css, .freebusy-block and
  // .freebusy-block.available). Two cues, neither of them colour, so the
  // legend must survive greyscale too.
  //
  // `legend.available` must never be phrased as "free time" in the sense of
  // "not busy": these blocks come only from events the owner explicitly
  // marked available, never from the gaps between busy ones.
  'legend.title': '表示の見かた',
  'legend.busy': '予定あり（内容は共有されません）',
  'legend.available': '共有者が空き時間として登録した時間',
  'legend.note': '空き時間として表示されていない時間が空いているとは限りません。',
  'legend.noteBusyOnly': '何も表示されていない時間が空いているとは限りません。',

  // --- share dialog (owner) ---------------------------------------------
  'shareDialog.title': '空き時間を共有',
  'shareDialog.created.title': '共有リンクを作成しました',
  'shareDialog.created.copy': 'コピー',
  'shareDialog.created.copied': 'コピー済',
  // Split so the <strong> emphasis survives translation. Both languages put
  // the stressed word mid-sentence, so three parts serve both.
  'shareDialog.created.warnBefore': 'このURLは',
  'shareDialog.created.warnEmphasis': '今だけ',
  'shareDialog.created.warnAfter':
    '表示されます。閉じると再表示できません（トークンは保存されません）。必要なら今すぐコピーして共有先へ渡してください。',
  'shareDialog.note.revokeTerm': '失効',
  'shareDialog.note.revokeBody': 'はURLを使えなくします。記録は残るため、総数の上限には数えられ続けます。',
  'shareDialog.note.deleteTerm': '削除',
  'shareDialog.note.deleteBody': 'は失効済みリンクの記録そのものを消し、総数の枠を空けます（元に戻せません）。',
  'shareDialog.label': 'ラベル（任意・管理用）',
  'shareDialog.labelPlaceholder': '例: 取引先A用',
  'shareDialog.includePrivate': '非公開(private)の予定も busy として含める',
  'shareDialog.shareAvailable': '「空き時間(Available)」として登録した予定も公開する',
  'shareDialog.shareAvailableHint':
    '公開されるのは、予定を「空き時間」として明示的に登録した時間だけです。予定が入っていない時間が自動的に空き時間として公開されることはありません。',
  'shareDialog.expiresAt': '有効期限（任意）',
  'shareDialog.expiry.past': '有効期限には未来の日時を指定してください',
  'shareDialog.expiry.foldUnchosen': '有効期限の時刻が2回あります。1回目か2回目を選んでから作成してください',
  'shareDialog.create': 'リンクを作成',
  'shareDialog.creating': '作成中…',
  'shareDialog.list.title': '既存のリンク',
  'shareDialog.list.revokedOnly': '失効済みのみ表示',
  'shareDialog.list.empty': 'リンクはまだありません。',
  'shareDialog.list.noRevoked': '失効済みのリンクはありません。',
  'shareDialog.list.noLabel': '(ラベルなし)',
  'shareDialog.status.active': '有効',
  'shareDialog.status.expired': '期限切れ',
  'shareDialog.status.revoked': '失効済',
  'shareDialog.sub.includePrivate': 'private含む',
  'shareDialog.sub.excludePrivate': 'private除外',
  'shareDialog.sub.availableShared': '空き時間を公開',
  'shareDialog.sub.availableHidden': '空き時間は非公開',
  'shareDialog.sub.expiresAt': '期限 {at}',
  'shareDialog.toggleAvailable': '空き時間(Available)を公開',
  'shareDialog.toggleUpdating': '（更新中…）',
  'shareDialog.expiredHint':
    '期限切れですが失効していません。削除するには、先に「失効」してください。',
  'shareDialog.revoke': '失効',
  'shareDialog.delete': '削除',
  'shareDialog.deleteConfirm': '削除する',
  'shareDialog.deleting': '削除中…',
  'shareDialog.confirmDelete': 'このリンクの記録を完全に削除します。元に戻せません。',
  'shareDialog.deleteRefused':
    'このリンクはすでに削除されたか、削除できない状態です。一覧を更新しました。',
  'shareDialog.availableRefused':
    'このリンクの設定を変更できませんでした。期限切れか失効している可能性があります。一覧を更新しました。',
  'shareDialog.note.urlOnce':
    '既存リンクのURLは再表示できません（作成時のみ表示）。分からなくなった場合は失効して作り直してください。',

  // --- calendar --------------------------------------------------------
  'calendar.untitled': '(無題)',
  'calendar.availableTitle': '空き時間',
  'calendar.visibility.private': '非公開',
  'calendar.visibility.privateShort': '非公開',
  'calendar.visibility.busyOnly': '予定あり（詳細非公開）',
  'calendar.visibility.busyOnlyShort': '予定あり',
  'calendar.visibility.public': '公開',
  'calendar.visibility.publicShort': '公開',
  // --- calendar toolbar -------------------------------------------------
  //
  // 'calendar.view.*' are the names of the three VIEWS, not weekday or month
  // names: the Japanese happens to be one character each because 月/週/日 are
  // also the units. English spells them out, and .toolbar wraps (flex-wrap),
  // so the longer labels need no layout change.
  //
  // 'calendar.prev' / '.next' are ACCESSIBLE NAMES. The buttons show only the
  // glyphs ‹ and ›, so these are the only thing a screen reader can announce,
  // and they stay generic because the step depends on the current view.
  'calendar.today': '今日',
  'calendar.prev': '前へ',
  'calendar.next': '次へ',
  'calendar.view.month': '月',
  'calendar.view.week': '週',
  'calendar.view.day': '日',
  // --- calendar display -------------------------------------------------
  //
  // THE CHIP'S TWO COMPOSITION PATTERNS, shared by all three places an event
  // is drawn: EventChip (month chips and week/day blocks), AllDayLane's bands
  // and MonthView's MonthBand. They were template literals, which is exactly
  // why they needed keys: the punctuation is language-specific. Japanese wraps
  // the visibility in full-width parentheses; English cannot.
  //
  // `{visibility}` is filled from visibilityMeta, which is still pinned to the
  // default language (a pure module cannot read a React context). P6 converts
  // it; until then these two compose a Japanese label either way.
  //
  // The accessible name uses a comma rather than parentheses, because a screen
  // reader pauses on a comma and reads a parenthesis as nothing at all.
  'calendar.chip.title': '{title}（{visibility}）',
  'calendar.chip.ariaLabel': '{title}, {visibility}',

  // The two overflow buttons. Both are the ACCESSIBLE NAME and the hover text
  // of a button whose visible content is just "+3", which says nothing about
  // what it opens.
  'calendar.more.events': '他 {count} 件の予定を表示',
  'calendar.more.allDay': '他 {count} 件の終日予定を表示',

  // 'calendar.allDay' is a ROW HEADING (the time grid's gutter, and the day
  // agenda's group heading), not the event form's checkbox -- event.field.allDay
  // is that one. They share a Japanese word and are kept apart so either can
  // change without the other.
  'calendar.allDay': '終日',
  'calendar.timed': '時刻あり',

  'calendar.agenda.empty': 'この日の予定はありません。',
  'calendar.share': '共有',
  'calendar.loadError': '読み込みエラー: {message}',
  'calendar.unexpandableSeries':
    '表示できない繰り返し予定があります（{count}件）。繰り返しの規則がこのアプリでは読み取れない形式のため、カレンダーには表示していません。ほかの予定はそのまま表示しています。共有ページでは、この予定がかかる期間の空き時間を判定できない場合があります。',
  // --- mobile calendar (P8-b2) -----------------------------------------
  //
  // The strip and the compact month draw a weekday, a number and a dot. The
  // dot is the only thing saying whether a day holds anything, and a dot has
  // no text, so 'dayLabel' is what a screen reader reads instead -- the date
  // in full, then one of the two phrases below.
  //
  // It says WHETHER, not how many: the desktop month cell does not print a
  // count either, and a phone should not disclose more than the desktop does.
  'calendar.mobile.week': '週の日付',
  'calendar.mobile.agenda': '一覧',
  'calendar.mobile.dayLabel': '{date}、{events}',
  'calendar.mobile.hasEvents': '予定あり',
  // 英語側の注記を参照。空き時間についての主張にならない言い方にする。
  'calendar.mobile.noEvents': '予定なし',
  'calendar.mobile.addOnDay': 'この日に予定を追加',

  // --- documentation (P7) ----------------------------------------------
  // The documentation screen itself is P7-e. These two exist so the routes
  // P7-a can already recognise have something honest to render instead of a
  // blank page -- a URL that resolves to nothing at all is the one outcome
  // worth ruling out from the start.
  'docs.title': 'ドキュメント',
  'docs.indexTitle': '使い方ガイド',
  'docs.indexLead': 'TimeWeave の使い方と、共有したときに相手に何が見えるのかを説明します。',
  'docs.backToApp': 'カレンダーへ戻る',
  'docs.backToIndex': 'ガイドの目次へ',
  'docs.skipToContent': '本文へ移動',
  'docs.onThisPage': 'このページの内容',
  'docs.prev': '前の章',
  'docs.next': '次の章',
  'docs.chapters': '章の一覧',
  'docs.group.events': '予定を作る',
  'docs.group.sharing': '共有する',
  'docs.group.settings': '設定',
  'docs.group.help': '困ったとき',
  // Shown INSTEAD of a translation, never alongside one that looks finished.
  // The reader is told which language they are actually reading, because a
  // page that quietly served another one would read as a broken page rather
  // than as work not yet done.
  'docs.fallbackNotice': 'この章はまだ英語に翻訳されていません。日本語の本文を表示しています。',
  'docs.notFound': 'お探しの章は見つかりませんでした。',
  'docs.notFoundHint': 'URL が変わったか、入力に誤りがあるかもしれません。目次からお探しください。',
  'docs.langSwitch': '表示言語',
  // The two options in the guide’s language picker.
  //
  // TRANSLATED, not endonyms. Showing 日本語 and English unchanged in both
  // dictionaries is the friendlier pattern, but it puts a Japanese string
  // into the English dictionary and a value identical across both -- the
  // two shapes the parity tests exist to catch, and neither has an
  // exception mechanism. Those checks are worth more than the small gain:
  // the picker shows two options side by side with the current one marked,
  // so the one being reached for is the other one either way.
  'docs.lang.ja': '日本語',
  'docs.lang.en': '英語',
  'docs.summary.getting-started': '最初に確認する設定と、カレンダーの3つの表示。',
  'docs.summary.managing-events': '入力項目の意味、終日の予定、編集と削除の注意点。',
  'docs.summary.recurring-events': '単発の予定との違い、指定できる規則と制限。',
  'docs.summary.privacy-and-availability': '公開範囲と状態の組み合わせ。共有を使う前にお読みください。',
  'docs.summary.share-links': 'リンクの作成、設定の変更、失効と削除。',
  'docs.summary.what-viewers-see': 'リンクを開いた相手の画面と、その表示の意味。',
  'docs.summary.time-zones': '終日の予定の日付、繰り返しと共有への影響。',
  'docs.summary.language': '日本語と英語の切り替え、相手の画面の言語。',
  'docs.summary.faq': '見えない・出ない・保存できないときの確認手順。',

  // --- app shell and sign-in -------------------------------------------
  //
  // The header's settings button reuses 'settings.title': it is the same
  // destination as the dialog's own heading, and one word in two places that
  // must agree is better served by one key than by two that can drift.
  //
  // 'app.themeToggle' is an ACCESSIBLE NAME. The button's visible content is
  // an emoji, so this is the whole announcement.
  'app.signOut': 'ログアウト',
  // 'app.menu' is an ACCESSIBLE NAME too: the trigger shows only a glyph, so
  // this is the whole of what a screen reader announces for it. It names the
  // thing the button opens, not the glyph.
  'app.menu': 'メニュー',
  'app.themeToggle': 'テーマ切替',

  // The sign-in screen. The tagline names what the app does, and it names
  // SHARING OPEN TIME rather than sharing a calendar -- the contents are never
  // shared, and the first screen should not suggest otherwise.
  'login.tagline': '予定を管理し、空き時間を共有する',
  'login.google': 'Google でログイン',

  // --- content limits --------------------------------------------------
  //
  // The ceiling travels as a variable so one wording serves every field and
  // the number cannot drift away from the constant it describes.
  'content.titleTooLong': 'タイトルは{max}文字以内で入力してください',
  'content.categoryTooLong': 'カテゴリは{max}文字以内で入力してください',
  'content.descriptionTooLong': 'メモは{max}文字以内で入力してください',

  // --- recurrence form validation --------------------------------------
  'recurrence.intervalTooSmall': '繰り返し間隔は 1 以上にしてください',
  // K13: the upper bound is MAX_INTERVAL (services/recurrence.ts), the server's own.
  'recurrence.intervalInvalid': '繰り返し間隔は 1〜9999 の整数で入力してください',
  'recurrence.countTooSmall': '繰り返し回数は 1 以上にしてください',
  // K14: the upper bound is MAX_COUNT (services/recurrence.ts), the server's own.
  'recurrence.countInvalid': '繰り返し回数は 1〜9,999,999 の整数で入力してください',
  'recurrence.untilRequired': '終了日を入力してください',
  // K17: LAST_TIMED_UNTIL_DATE (recurrenceForm.ts).
  'recurrence.untilOutOfRange': '時刻を指定した繰り返しの終了日は 9999年12月30日 までにしてください',

  // --- settings notices -------------------------------------------------
  'settings.timezone.changeAllDay': '終日の予定は、このタイムゾーンの暦日として解釈されます。',
  'settings.timezone.changeShare': '匿名共有ページに表示される空き時間が変わることがあります。',
  'settings.timezone.changeTimedUnaffected':
    '時刻を指定した予定（開始・終了時刻のある予定）は変わりません。',
  'settings.timezone.unsetNotice':
    'タイムゾーンが未設定のため、終日の予定と時刻指定の空き時間が同じ期間に含まれる場合、匿名共有ページでは空き時間を表示できません（安全のため非表示になります）。',
  'settings.language.notInCalculation': '言語設定は、共有される空き時間の計算には影響しません。',

  // --- event ----------------------------------------------------------
  'event.title.required': 'タイトルを入力してください',
  'event.untitled': '(無題)',
  // --- recurrence editor (the fieldset inside the event dialog) ----------
  //
  // 'recurrence.end.count' / '.until' are the SELECT OPTIONS; '.count.label' /
  // '.until.label' are the field labels that appear once that option is
  // chosen. They share a Japanese string and must not share a key: English
  // needs "After a number of repeats" for the option and "Number of repeats"
  // for the field it reveals.
  //
  // Weekday names are NOT here and never will be: they are a date format, and
  // i18n/dateNames.ts holds the one table all four views read (P4 step 1).
  // Fourteen loose keys would let a translator reorder the week.
  'recurrence.legend': '繰り返し',
  'recurrence.freq.label': '頻度',
  'recurrence.freq.none': '繰り返さない',
  'recurrence.freq.daily': '毎日',
  'recurrence.freq.weekly': '毎週',
  'recurrence.freq.monthly': '毎月',
  'recurrence.interval.label': '間隔',
  'recurrence.weekdays.label': '曜日',
  'recurrence.end.label': '終了',
  'recurrence.end.never': '終わりなし',
  'recurrence.end.count': '回数',
  'recurrence.end.until': '終了日',
  'recurrence.count.label': '回数',
  'recurrence.until.label': '終了日',

  // --- event dialog -----------------------------------------------------
  'event.dialog.create': '予定を追加',
  'event.dialog.edit': '予定を編集',

  // The edit scope. These decide which row a save lands on, so the two
  // options have to stay unmistakable: one occurrence versus the whole
  // series.
  'event.scope.label': '対象',
  'event.scope.only': 'この回のみ',
  'event.scope.all': 'すべての回',

  'event.field.title': 'タイトル',
  'event.field.allDay': '終日',
  'event.field.startDate': '開始日',
  'event.field.endDate': '終了日',
  'event.field.start': '開始',
  'event.field.end': '終了',
  'event.field.description': 'メモ',
  'event.memo.done': '完了',
  'event.memo.doneLabel': 'メモの入力を終える',
  'event.field.category': 'カテゴリ',
  'event.field.visibility': '公開範囲',
  'event.field.availability': '状態',

  // THE STORED VALUE IS PART OF THE LABEL, in both languages. These three
  // words decide how much of the row a share link may disclose, and the
  // parenthesised enum is what lets the owner match what they picked against
  // everything else that names it -- the share dialog, the docs, the RPC.
  // Translating the word while dropping the value would make the control
  // ambiguous in exactly the place it must not be.
  'event.visibility.private': '非公開 (private)',
  'event.visibility.busyOnly': '予定ありのみ (busy_only)',
  'event.visibility.public': '公開 (public)',

  // The two values of the `状態` control -- the only place the app names them
  // for an owner choosing one.
  //
  // THE ENGLISH TERM IS PART OF THE JAPANESE LABEL, and that is exactly what
  // leaving this untranslated used to protect. `Busy` and `Available` are the
  // words the rest of the product uses in Japanese too: the share dialog says
  // 空き時間(Available), the user guide says the same, and the stored value is
  // `available`. A bare 空き時間 would read more naturally and would quietly
  // break that correspondence -- an owner could no longer match what they
  // picked here against the checkbox that decides whether it is shared.
  // Keeping the term in parentheses gives both: a Japanese name to read, and
  // the word everything else names.
  //
  // English carries no parenthetical, unlike the visibility options above. It
  // would add nothing: there the enum (`busy_only`) differs from the label
  // ("Busy only"), while here the label already IS the term.
  'event.availability.busy': '予定あり (Busy)',
  'event.availability.available': '空き時間 (Available)',

  'event.error.dateRequired': '日付を入力してください',
  'event.error.endDateBeforeStart': '終了日は開始日以降にしてください',
  'event.error.endBeforeStart': '終了日時は開始日時以降にしてください',
  // K18: the database's own bounds (eventDateBounds.ts, 0013).
  'event.error.allDayOutOfRange': '終日の予定は 9999年12月30日 までの日付にしてください',
  'event.error.timedOutOfRange': 'この日時は保存できる範囲を超えています。協定世界時（UTC）で 9999年12月31日 のうちに終わる日時にしてください',

  // The two zone refusals. Neither offers a fallback, and the translation
  // must not invent one: a timed recurrence repeats at a wall-clock time, so
  // guessing UTC would silently move every occurrence.
  'event.tz.unresolved':
    'タイムゾーンを判定できないため、時刻ありの繰り返し予定は保存できません。ブラウザの日付と時刻の設定をご確認ください',
  'event.tz.unavailable':
    'ブラウザからタイムゾーンを取得できないため、設定できません。ブラウザの日付と時刻の設定をご確認ください',

  'event.tz.recurrence': '繰り返しのタイムゾーン: {timezone}',
  'event.tz.label': 'タイムゾーン',
  'event.tz.unset': '未設定',
  'event.tz.setCurrent': '現在のタイムゾーン ({timezone}) を設定',
  'event.tz.setCurrentUnknown': '現在のタイムゾーンを設定',
  'event.tz.changeToCurrent': '現在のタイムゾーン ({timezone}) に変更',

  // ---- date/time inputs (P8-b5.6b-2) ----
  'event.dt.date': '日付',
  'event.dt.time': '時刻',
  'event.dt.openCalendar': 'カレンダーで選ぶ',
  'event.dt.openClock': '時計で選ぶ',
  'event.dt.dateHint': '20261019・2026-10-19・2026/10/19 のどれでも入力できます。Enter で確定、Esc で元に戻す、↑↓ で1日ずつ移動',
  'event.dt.timeHint': '1430・14:30・930・9:30 のどれでも入力できます。Enter で確定、Esc で元に戻す、↑↓ でカーソル位置の時・分を1ずつ変更',
  'event.dt.dateFormat': '形式: 年4桁・月2桁・日2桁。区切りは省略できます',
  'event.dt.timeFormat': '形式: 24時間制で時2桁・分2桁。コロンは省略できます',
  'event.dt.date.format': '日付は 20261019・2026-10-19・2026/10/19 のいずれかで入力してください',
  'event.dt.date.nonexistent': '「{value}」は存在しない日付です',
  'event.dt.time.empty': '時刻を入力してください',
  'event.dt.time.format': '時刻は 1430・14:30・930・9:30 のいずれかで入力してください',
  'event.dt.time.hourRange': '「{value}」は入力できません。時は 0〜23 です（翌日の 0 時は日付を翌日にして 00:00）',
  'event.dt.time.minuteRange': '「{value}」は入力できません。分は 00〜59 です',
  'event.dt.time.ambiguous': '「{value}」は 09:05 か 09:50 か判別できません。分は2桁で入力してください',
  'event.dt.draftInvalid': '入力途中の日時が正しくありません。赤い欄を直してから保存してください',
  'event.dt.cal.prevMonth': '前の月',
  'event.dt.cal.nextMonth': '次の月',
  'event.dt.cal.prevYear': '前の年',
  'event.dt.cal.nextYear': '次の年',
  'event.dt.cal.prevYears': '前の12年',
  'event.dt.cal.nextYears': '次の12年',
  'event.dt.cal.today': '今日へ',
  'event.dt.cal.digitsHint': '数字8桁（20261019）でも入力できます',
  'event.dt.toText': '文字で入力',
  'event.dt.toCalendar': 'カレンダーで選ぶ',
  'event.dt.toDial': '時計で選ぶ',
  'event.dt.confirm': '決定',
  'event.dt.clock.hours': '時',
  'event.dt.clock.minutes': '分',
  'event.dt.clock.minus1': '1分戻す',
  'event.dt.clock.plus1': '1分進める',
  'event.dt.clock.hourRange': '0〜23',
  'event.dt.clock.minuteRange': '0〜59',
  'event.dt.dst.gap': 'この時刻は存在しません。{date} は {before} の次が {after} です（夏時間で時計が {minutes} 分進みます）。時刻を変更してください',
  'event.dt.dst.fold': 'この時刻は2回あります（夏時間の終わりで時計が戻ります）。どちらか選んでください',
  'event.dt.dst.first': '1回目',
  'event.dt.dst.second': '2回目',
  'event.dt.dst.gapSave': '存在しない時刻があります（夏時間の切り替え）。時刻を変更してから保存してください',
  'event.dt.dst.foldSave': '2回ある時刻です。1回目か2回目を選んでから保存してください',
} as const;

/** Every key the app may ask for. Derived, never written out by hand. */
export type MessageKey = keyof typeof ja;
