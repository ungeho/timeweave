/**
 * The English dictionary.
 *
 * Declared `as const` for the same reason `ja` is -- the literal types are what
 * let `dictionaries.ts` compare placeholder sets between the two at COMPILE
 * time, not just key sets. A missing key, a key that exists only here, or a
 * message whose `{placeholders}` differ from the Japanese one all fail `tsc`.
 *
 * TRANSLATION IS NOT SUBSTITUTION. Two entries below carry safety meaning that
 * a natural-sounding rewrite would destroy, and both are pinned by tests that
 * assert what the English must NOT say:
 *
 *   share.available.indeterminate  reports that open time COULD NOT BE
 *     DETERMINED. "No availability" / "not available" would turn an absence of
 *     knowledge into a claim about the owner's calendar, which is the one
 *     mistake the three-state design exists to prevent.
 *   share.available.empty  says nothing is SHARED, not that nothing exists.
 *     The owner may have open time they simply did not publish.
 */

import type { MessageKey } from './ja';

export const en = {
  // --- common ---------------------------------------------------------
  'common.save': 'Save',
  'common.cancel': 'Cancel',
  'common.close': 'Close',
  'common.delete': 'Delete',
  'common.saving': 'Saving…',
  'common.loading': 'Loading…',

  // --- settings -------------------------------------------------------
  'settings.title': 'Settings',
  'settings.signedInAs': 'Signed in as',
  'settings.timezone.label': 'Time zone',
  'settings.language.label': 'Display language',
  'settings.language.followBrowser': 'Follow browser setting',
  'settings.saved': 'Settings saved.',
  // "Not set" is a real state, so clearing the field is described as going
  // back to it rather than as leaving the value blank.
  'settings.timezone.hint':
    'Decides which calendar day an all-day event belongs to. Leave it empty for no time zone.',

  // A confirmation, not an error. "Change it" is the affirmative action, kept
  // clearly distinct from the Cancel beside it.
  'settings.timezone.confirmTitle': 'Your time zone will be changed.',
  'settings.timezone.confirmApply': 'Change it',

  // --- share ----------------------------------------------------------
  'share.label.count': '{count} / {max}',
  'share.label.tooLong': 'The label must be {max} characters or fewer',
  'share.link.status': '{label} — {status}',

  'share.available.indeterminate':
    'Open time could not be determined for this period. Please get in touch directly to check availability.',

  'share.available.empty': 'No open time is shared for this period.',

  'error.unknownCause': 'the cause could not be determined',

  // --- errors ---------------------------------------------------------
  //
  // Each of these keeps the distinction its Japanese counterpart carries:
  // what happened, whether the user can act on it, and what to do. The quota
  // messages deliberately omit the ceiling -- the database owns that number
  // (events_max_per_owner() and friends) and a copy here could drift.
  'error.retry.wait': 'Please wait a moment and try again',
  // ABBREVIATED UNITS, DELIBERATELY. `{seconds}` can be 1 and `{minutes}`
  // is 1 for every window of 60 seconds or less (retryAdvice does
  // Math.ceil(seconds / 60)), so "about 1 minutes" was not a rare edge
  // case -- it was the usual output. English has no invariant plural, and
  // this layer has no plural rules, so the units are abbreviated instead:
  // "1 min" and "3 min" are both correct and both idiomatic in a UI.
  // Proper plural selection is a translation-API change; see the P5 audit.
  'error.retry.seconds': 'Please try again in about {seconds} sec',
  'error.retry.minutes': 'Please try again in about {minutes} min',

  'error.duplicateException': 'This occurrence already has its own change',
  'error.seriesEditBlocked':
    'Some occurrences have been changed individually, so the whole series cannot be edited',
  'error.writeRateLimited': 'Saving is temporarily limited after too many changes at once. {advice}',
  'error.freeBusyRateLimited':
    'Loading free/busy is temporarily limited after too many requests at once. {advice}',
  // NOT "is busy": this app uses Busy as an availability term, and a
  // sentence with both meanings five words apart is unreadable. "already"
  // is also the more accurate word -- 0019 raises this when a computation
  // for the same calendar is already in flight.
  'error.freeBusyBusy': 'Free/busy is already being calculated. {advice}',
  'error.shareLinkRateLimited':
    'Creating share links is temporarily limited after too many at once. {advice}',
  'error.shareLinkActiveQuota':
    'You have reached the limit for active share links. Revoke one you no longer need and try again',
  'error.shareLinkTotalQuota':
    'You have reached the limit for share links in total. Deleting a revoked link frees a slot (revoking alone does not reduce the total). If you have none revoked, revoke one you no longer need first',
  'error.recurrenceGraph': 'The event could not be saved. Please try again.',
  'error.eventQuota':
    'You have reached the limit for stored events. Delete one you no longer need and try again',
  'error.exceptionQuota':
    'This repeating event has reached its limit for per-occurrence changes. Tidy those changes and try again',
  'error.invalidTimezone':
    'This time zone cannot be used. Please check your browser’s date and time settings',
  'error.timezoneRequired':
    'The time zone for this repeating event could not be determined, so it was not saved',
  'error.timezoneCleared': 'The time zone of a repeating event cannot be removed',

  // Two more specific wordings for existing codes. Both say WHICH rule was
  // broken; neither offers a fallback zone, because a guessed zone silently
  // changes which instants a series occupies.
  'error.timezonePlacement':
    'Only a repeating event with a start and end time can carry a time zone',
  'error.seriesTimezoneBlocked':
    'Some occurrences have been changed individually, so the time zone of the series cannot be changed',

  // --- share page (pure presentation modules) --------------------------
  //
  // `share.unavailable` names no reason, in English either: expired, revoked,
  // deleted, unknown and malformed are one state by design (0023), and saying
  // which would hand an observer the oracle the whole thing withholds.
  // `share.activeEmpty` says nothing is SHARED, not that the owner is free.
  'share.unavailable': 'This share link is not available.',
  'share.activeEmpty': 'No events are shared for this period.',
  'share.error.generic': 'Free/busy could not be loaded. Please wait a moment and reload.',
  'share.error.notFreeNote': ' (this screen does not mean “no events”)',

  // --- share page (anonymous viewer) -----------------------------------
  'sharePage.subtitle': 'Free/busy (read-only)',
  'sharePage.disabled': 'Sharing is not available.',
  'sharePage.thisWeek': 'This week',
  'sharePage.prevWeek': 'Previous week',
  'sharePage.nextWeek': 'Next week',
  'sharePage.loading': 'Loading…',
  // "expanded" was RRULE jargon in a string an ANONYMOUS viewer reads. What
  // they need to know is that the picture is incomplete, which the first
  // sentence now says plainly; the caveat is unchanged and non-negotiable.
  'sharePage.incompleteWarning':
    'Some repeating events in this period could not be included. Times not shown are not necessarily free.',
  'sharePage.block.busyAllDay': 'All day — busy',
  'sharePage.block.busy': 'Busy',
  'sharePage.block.availableAllDay': 'All day — open',
  'sharePage.block.timeRange': '{state}, {start} to {end}',
  'sharePage.block.available': 'Open',
  'sharePage.day.nothing': 'Nothing shown',
  'sharePage.footer.busyOnly':
    'Only whether there is an event (busy) is shown; the contents are not shared.',
  'sharePage.footer.withAvailable':
    'Only whether there is an event (busy) and the open time the owner marked (available) are shown; the contents are not shared. Time not shown as open is not necessarily free.',

  // --- share page legend (shown since P8-mobile-2) -----------------------
  //
  // Says what each block MEANS, not what colour it is: the contract is filled
  // versus outlined plus a hatch, so the wording has to work in greyscale.
  // `legend.available` is phrased as time the owner MARKED, never as "free
  // time" -- these blocks never come from the gaps between busy ones.
  'legend.title': 'How to read this',
  'legend.busy': 'Busy (the contents are not shared)',
  'legend.available': 'Time the owner marked as open',
  'legend.note': 'Time not shown as open is not necessarily free.',
  'legend.noteBusyOnly': 'Time with nothing shown is not necessarily free.',

  // --- share dialog (owner) ---------------------------------------------
  'shareDialog.title': 'Share your free/busy',
  'shareDialog.created.title': 'Share link created',
  'shareDialog.created.copy': 'Copy',
  'shareDialog.created.copied': 'Copied',
  // "shown only now" was a literal rendering of 今だけ and is not idiomatic.
  // "only once" says the same thing in English and keeps the emphasis on
  // the same span, which is what the three-part split exists to preserve.
  'shareDialog.created.warnBefore': 'This URL is shown ',
  'shareDialog.created.warnEmphasis': 'only once',
  'shareDialog.created.warnAfter':
    '. Once you close this it cannot be shown again (the token is not stored), so copy it now if you need it.',
  'shareDialog.note.revokeTerm': 'Revoking',
  // Trailing space: the next thing rendered is <strong>Deleting</strong>, and
  // the newline between them in the JSX is dropped. Japanese needs no such
  // space, which is why this belongs here and not in the markup.
  'shareDialog.note.revokeBody':
    ' stops the URL working. The record remains, so it still counts towards the total. ',
  'shareDialog.note.deleteTerm': 'Deleting',
  'shareDialog.note.deleteBody':
    ' removes the record of a revoked link and frees a slot (this cannot be undone).',
  'shareDialog.label': 'Label (optional, for your reference)',
  'shareDialog.labelPlaceholder': 'e.g. for client A',
  'shareDialog.includePrivate': 'Include private events as busy',
  'shareDialog.shareAvailable': 'Also share events marked as open time (Available)',
  'shareDialog.shareAvailableHint':
    'Only time you explicitly marked as open is shared. Time with no events is never published as open automatically.',
  'shareDialog.expiresAt': 'Expiry (optional)',
  'shareDialog.expiry.past': 'Choose a future date and time for the expiry',
  'shareDialog.expiry.foldUnchosen': 'The expiry time happens twice. Choose the 1st or the 2nd before creating the link',
  'shareDialog.create': 'Create link',
  'shareDialog.creating': 'Creating…',
  'shareDialog.list.title': 'Existing links',
  'shareDialog.list.revokedOnly': 'Show revoked only',
  'shareDialog.list.empty': 'No links yet.',
  'shareDialog.list.noRevoked': 'No revoked links.',
  'shareDialog.list.noLabel': '(no label)',
  'shareDialog.status.active': 'Active',
  'shareDialog.status.expired': 'Expired',
  'shareDialog.status.revoked': 'Revoked',
  'shareDialog.sub.includePrivate': 'private included',
  'shareDialog.sub.excludePrivate': 'private excluded',
  'shareDialog.sub.availableShared': 'open time shared',
  'shareDialog.sub.availableHidden': 'open time not shared',
  'shareDialog.sub.expiresAt': 'expires {at}',
  'shareDialog.toggleAvailable': 'Share open time (Available)',
  'shareDialog.toggleUpdating': ' (updating…)',
  'shareDialog.expiredHint':
    'Expired but not revoked. To delete it, revoke it first.',
  'shareDialog.revoke': 'Revoke',
  'shareDialog.delete': 'Delete',
  'shareDialog.deleteConfirm': 'Delete it',
  'shareDialog.deleting': 'Deleting…',
  'shareDialog.confirmDelete': 'This permanently deletes the record of this link. It cannot be undone.',
  'shareDialog.deleteRefused':
    'This link has already been deleted, or cannot be deleted. The list has been refreshed.',
  'shareDialog.availableRefused':
    'This link’s setting could not be changed. It may be expired or revoked. The list has been refreshed.',
  'shareDialog.note.urlOnce':
    'The URL of an existing link cannot be shown again (only at creation). If you lose it, revoke the link and create a new one.',

  // --- calendar --------------------------------------------------------
  'calendar.untitled': '(untitled)',
  'calendar.availableTitle': 'Open time',
  'calendar.visibility.private': 'Private',
  'calendar.visibility.privateShort': 'Private',
  // No parentheses of its own: the chip composes "{title} ({visibility})",
  // so a parenthesised label nests -- "Dentist (Busy (details hidden))".
  'calendar.visibility.busyOnly': 'Busy — details hidden',
  'calendar.visibility.busyOnlyShort': 'Busy',
  'calendar.visibility.public': 'Public',
  'calendar.visibility.publicShort': 'Public',
  // --- calendar toolbar -------------------------------------------------
  //
  // The three VIEWS, spelled out: the Japanese is one character each only
  // because 月/週/日 double as the units. Not weekday or month names, which
  // P4 handles with the date formats.
  //
  // 'calendar.prev' / '.next' are the accessible names of two buttons whose
  // only visible content is ‹ and ›, so they are the whole announcement.
  'calendar.today': 'Today',
  'calendar.prev': 'Previous',
  'calendar.next': 'Next',
  'calendar.view.month': 'Month',
  'calendar.view.week': 'Week',
  'calendar.view.day': 'Day',
  // --- calendar display -------------------------------------------------
  //
  // The chip's two composition patterns. Japanese wraps the visibility in
  // full-width parentheses; English uses ordinary ones with a space, which is
  // the whole reason these are keys and not a template literal in the
  // component.
  //
  // The accessible name keeps the comma in both languages: a screen reader
  // pauses on it and announces nothing for a parenthesis.
  'calendar.chip.title': '{title} ({visibility})',
  'calendar.chip.ariaLabel': '{title}, {visibility}',

  // THE NOUN IS OMITTED ON PURPOSE. `{count}` is 1 or more, and this layer has
  // no plural rules, so "Show 1 more events" would be reachable. "Show 1 more"
  // and "Show 1 more in the all-day row" are correct at every count, and the
  // second still says WHICH overflow this is -- the distinction the Japanese
  // carries with 予定 versus 終日予定. Proper plural handling is a P5 question,
  // and these are the first two keys where it would bite.
  'calendar.more.events': 'Show {count} more',
  'calendar.more.allDay': 'Show {count} more in the all-day row',

  // A row heading, not the event form's checkbox (event.field.allDay).
  'calendar.allDay': 'All day',
  'calendar.timed': 'Timed',

  'calendar.agenda.empty': 'Nothing is scheduled on this day.',
  'calendar.share': 'Share',
  'calendar.loadError': 'Could not load: {message}',
  'calendar.unexpandableSeries':
    'Recurring events that cannot be shown: {count}. Their repeat rule is in a form this app cannot read, so they are left off the calendar; your other events are shown as usual. On a share page, open time may not be determinable for the periods they cover.',
  // --- mobile calendar (P8-b2) -----------------------------------------
  // See the note in ja.ts: 'dayLabel' is what a screen reader gets in place
  // of a dot, and it says whether rather than how many.
  'calendar.mobile.week': 'Days of the week',
  'calendar.mobile.agenda': 'Agenda',
  'calendar.mobile.dayLabel': '{date}, {events}',
  'calendar.mobile.hasEvents': 'has events',
  // NOT "no events" or "free": a calendar key saying either reads as a claim
  // about availability, which is the one thing absence of events never is.
  // This describes the owner's own day, so it says what is actually true of
  // it -- nothing is scheduled -- and makes no claim beyond that.
  'calendar.mobile.noEvents': 'nothing scheduled',
  'calendar.mobile.addOnDay': 'Add an event on this day',

  // --- documentation (P7) ----------------------------------------------
  'docs.title': 'Documentation',
  'docs.indexTitle': 'User guide',
  'docs.indexLead': 'How TimeWeave works, and what someone you share with actually sees.',
  'docs.backToApp': 'Back to the calendar',
  'docs.backToIndex': 'Guide contents',
  'docs.skipToContent': 'Skip to content',
  'docs.onThisPage': 'On this page',
  'docs.prev': 'Previous',
  'docs.next': 'Next',
  'docs.chapters': 'Chapters',
  'docs.group.events': 'Keeping a calendar',
  'docs.group.sharing': 'Sharing',
  'docs.group.settings': 'Settings',
  'docs.group.help': 'When something is wrong',
  'docs.fallbackNotice': 'This chapter has not been translated yet. You are reading the Japanese text.',
  'docs.notFound': 'That chapter could not be found.',
  'docs.notFoundHint': 'The URL may have changed, or there may be a typo. Try the contents.',
  'docs.langSwitch': 'Language',
  // See the note in ja.ts: translated rather than endonyms, so the parity
  // checks keep working.
  'docs.lang.ja': 'Japanese',
  'docs.lang.en': 'English',
  'docs.summary.getting-started': 'The settings to check first, and the three calendar views.',
  'docs.summary.managing-events': 'What each field means, all-day events, editing and deleting.',
  'docs.summary.recurring-events': 'How a series differs from one event, and what it can express.',
  'docs.summary.privacy-and-availability': 'Visibility and availability together. Read this before sharing.',
  'docs.summary.share-links': 'Creating a link, changing it, revoking and deleting.',
  'docs.summary.what-viewers-see': 'The screen someone gets from your link, and what it means.',
  'docs.summary.time-zones': 'Which day an all-day event falls on, and what that does to sharing.',
  'docs.summary.language': 'Japanese and English, and which one a viewer gets.',
  'docs.summary.faq': 'What to check when something is not shown or will not save.',

  // --- app shell and sign-in -------------------------------------------
  //
  // The header's settings button reuses 'settings.title' -- the same
  // destination as the dialog heading, so one key rather than two.
  //
  // 'app.themeToggle' is the accessible name of a button whose visible
  // content is an emoji.
  'app.signOut': 'Sign out',
  // An accessible name, like app.themeToggle: the trigger is a glyph.
  'app.menu': 'Menu',
  'app.themeToggle': 'Toggle theme',

  // Shares OPEN TIME, not the calendar: the contents are never shared, and
  // the first screen must not imply they are.
  'login.tagline': 'Manage your schedule and share your open time',
  'login.google': 'Sign in with Google',

  // --- content limits --------------------------------------------------
  'content.titleTooLong': 'Title must be {max} characters or fewer',
  'content.categoryTooLong': 'Category must be {max} characters or fewer',
  'content.descriptionTooLong': 'Notes must be {max} characters or fewer',

  // --- recurrence form validation --------------------------------------
  'recurrence.intervalTooSmall': 'The repeat interval must be 1 or more',
  'recurrence.intervalInvalid': 'The repeat interval must be a whole number from 1 to 9999',
  'recurrence.countTooSmall': 'The number of repeats must be 1 or more',
  'recurrence.countInvalid': 'The number of repeats must be a whole number from 1 to 9,999,999',
  'recurrence.untilRequired': 'Please enter an end date',
  'recurrence.untilOutOfRange': 'A repeating event with a time must end on or before December 30, 9999',

  // --- settings notices -------------------------------------------------
  'settings.timezone.changeAllDay':
    'All-day events will be read as calendar days in this time zone.',
  'settings.timezone.changeShare':
    'The open time shown on the anonymous share page may change.',
  'settings.timezone.changeTimedUnaffected':
    'Events with a start and end time are unaffected.',
  'settings.timezone.unsetNotice':
    'No time zone is set, so when a period contains both all-day events and timed open time, the anonymous share page cannot show open time (it is hidden to stay safe).',
  'settings.language.notInCalculation':
    'The language setting does not affect how shared open time is calculated.',

  // --- event ----------------------------------------------------------
  'event.title.required': 'Please enter a title',
  'event.untitled': '(untitled)',
  // --- recurrence editor (the fieldset inside the event dialog) ----------
  //
  // The option and the field it reveals are separate keys because English
  // needs different wording for each: picking "after a number of repeats"
  // then being asked for the "number of repeats".
  'recurrence.legend': 'Repeat',
  'recurrence.freq.label': 'Frequency',
  'recurrence.freq.none': 'Does not repeat',
  'recurrence.freq.daily': 'Daily',
  'recurrence.freq.weekly': 'Weekly',
  'recurrence.freq.monthly': 'Monthly',
  'recurrence.interval.label': 'Interval',
  'recurrence.weekdays.label': 'Days of the week',
  'recurrence.end.label': 'Ends',
  'recurrence.end.never': 'Never',
  'recurrence.end.count': 'After a number of repeats',
  'recurrence.end.until': 'On a date',
  'recurrence.count.label': 'Number of repeats',
  'recurrence.until.label': 'End date',

  // --- event dialog -----------------------------------------------------
  'event.dialog.create': 'Add event',
  'event.dialog.edit': 'Edit event',

  // "This occurrence" versus "all occurrences" is the distinction that
  // decides which row a save lands on. Neither may be shortened to something
  // that could be read as the other.
  'event.scope.label': 'Apply to',
  'event.scope.only': 'This occurrence only',
  'event.scope.all': 'All occurrences',

  'event.field.title': 'Title',
  'event.field.allDay': 'All day',
  'event.field.startDate': 'Start date',
  'event.field.endDate': 'End date',
  'event.field.start': 'Start',
  'event.field.end': 'End',
  'event.field.description': 'Notes',
  'event.memo.done': 'Done',
  'event.memo.doneLabel': 'Finish editing the notes',
  'event.field.category': 'Category',
  'event.field.visibility': 'Visibility',
  // NOT "Status": the control offers Busy and Available, and "Status: Busy"
  // reads as the status of the save rather than of the time. The Japanese
  // 状態 is equally vague, but English has the exact word and the column is
  // called `availability`, so the label says so.
  'event.field.availability': 'Availability',

  // The stored value stays in the label. `busy_only` is "busy only", never
  // "public": it discloses that there IS an event and withholds everything
  // else, and the label is where the owner reads that promise.
  'event.visibility.private': 'Private (private)',
  'event.visibility.busyOnly': 'Busy only (busy_only)',
  'event.visibility.public': 'Public (public)',

  'event.availability.busy': 'Busy',
  'event.availability.available': 'Available',

  'event.error.dateRequired': 'Please enter a date',
  'event.error.endDateBeforeStart': 'The end date must be on or after the start date',
  'event.error.endBeforeStart': 'The end must be at or after the start',
  'event.error.allDayOutOfRange': 'An all-day event must end on or before December 30, 9999',
  'event.error.timedOutOfRange': 'This time is beyond what can be saved. It must end by the end of December 31, 9999 in UTC',

  // Neither refusal offers a fallback zone, and neither may acquire one in
  // translation: a timed recurrence repeats at a wall-clock time, so guessing
  // would silently move every occurrence.
  'event.tz.unresolved':
    'A time zone could not be determined, so a repeating event with a time cannot be saved. Please check your browser’s date and time settings',
  'event.tz.unavailable':
    'A time zone could not be read from your browser, so it cannot be set. Please check your browser’s date and time settings',

  'event.tz.recurrence': 'Time zone of the repeat: {timezone}',
  'event.tz.label': 'Time zone',
  'event.tz.unset': 'Not set',
  'event.tz.setCurrent': 'Set the current time zone ({timezone})',
  'event.tz.setCurrentUnknown': 'Set the current time zone',
  'event.tz.changeToCurrent': 'Change to the current time zone ({timezone})',

  // ---- date/time inputs (P8-b5.6b-2) ----
  'event.dt.date': 'Date',
  'event.dt.time': 'Time',
  'event.dt.openCalendar': 'Pick a date',
  'event.dt.openClock': 'Pick a time',
  'event.dt.dateHint': 'Type 20261019, 2026-10-19 or 2026/10/19. Enter confirms, Esc reverts, the arrow keys move one day',
  'event.dt.timeHint': 'Type 1430, 14:30, 930 or 9:30. Enter confirms, Esc reverts, the arrow keys step the hour or minute under the cursor',
  'event.dt.dateFormat': 'Format: 4-digit year, 2-digit month, 2-digit day. Separators are optional',
  'event.dt.timeFormat': 'Format: 24-hour, 2-digit hours and minutes. The colon is optional',
  'event.dt.date.format': 'Enter the date as 20261019, 2026-10-19 or 2026/10/19',
  'event.dt.date.nonexistent': '“{value}” is not a real date',
  'event.dt.time.empty': 'Please enter a time',
  'event.dt.time.format': 'Enter the time as 1430, 14:30, 930 or 9:30',
  'event.dt.time.hourRange': '“{value}” is out of range. Hours run from 0 to 23 (for midnight, use 00:00 on the next day)',
  'event.dt.time.minuteRange': '“{value}” is out of range. Minutes run from 00 to 59',
  'event.dt.time.ambiguous': '“{value}” could be 09:05 or 09:50. Type the minutes with two digits',
  'event.dt.draftInvalid': 'A date or time is not valid yet. Fix the field marked in red, then save',
  'event.dt.cal.prevMonth': 'Previous month',
  'event.dt.cal.nextMonth': 'Next month',
  'event.dt.cal.prevYear': 'Previous year',
  'event.dt.cal.nextYear': 'Next year',
  'event.dt.cal.prevYears': 'Previous 12 years',
  'event.dt.cal.nextYears': 'Next 12 years',
  'event.dt.cal.today': 'Today',
  'event.dt.cal.digitsHint': 'Eight digits (20261019) work too',
  'event.dt.toText': 'Type instead',
  'event.dt.toCalendar': 'Use the calendar',
  'event.dt.toDial': 'Use the clock',
  'event.dt.confirm': 'OK',
  'event.dt.clock.hours': 'Hours',
  'event.dt.clock.minutes': 'Minutes',
  'event.dt.clock.minus1': 'One minute earlier',
  'event.dt.clock.plus1': 'One minute later',
  'event.dt.clock.hourRange': '0–23',
  'event.dt.clock.minuteRange': '0–59',
  'event.dt.dst.gap': 'This time does not exist. On {date}, {before} is followed by {after} (clocks jump ahead {minutes} min for daylight saving). Please change the time',
  'event.dt.dst.fold': 'This time happens twice (clocks go back as daylight saving ends). Choose which one',
  'event.dt.dst.first': '1st',
  'event.dt.dst.second': '2nd',
  'event.dt.dst.gapSave': 'A time does not exist (daylight saving change). Change it, then save',
  'event.dt.dst.foldSave': 'A time happens twice. Choose the 1st or the 2nd, then save',
} as const;

/**
 * Key parity, both directions, as a compile-time assertion.
 *
 * `Record<MessageKey, string>` would catch a MISSING key but not an EXTRA one
 * once the object is declared separately and widened, and it would also throw
 * away the literal types this file needs. Asserting the two key sets include
 * each other keeps both checks and the literals.
 */
type EnKey = keyof typeof en;
type _MissingInEn = Exclude<MessageKey, EnKey>;
type _ExtraInEn = Exclude<EnKey, MessageKey>;

// Both must be `never`. A key added to ja and forgotten here, or a stale key
// left here after ja dropped it, makes one of these a union and fails tsc.
const _keyParity: [_MissingInEn, _ExtraInEn] extends [never, never] ? true : never = true;
void _keyParity;
