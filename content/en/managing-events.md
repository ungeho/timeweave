---
id: managing-events
lang: en
title: Events
sourceHash: 18f55605cfff37cd
---

# Events

The fields in the event dialog, and what to watch out for when editing or
deleting.

## Creating an event

On a computer, pick the day or time you want on the calendar and the event
dialog opens. On a phone, choose a day in the calendar's **Agenda** and press
**Add an event on this day**. Fill it in and press **Save** to store it;
closing it with **Cancel** saves nothing.

On a phone the event dialog becomes a full-screen editor (see **Editing an
event on a phone** below). The fields are the same as on a computer.

## The fields

![The add-event dialog, with fields for title, all day, start and end (each a date field and a time field, the date with its weekday and a calendar button, the time with a clock button), notes, category, visibility, availability and repeat, and cancel and save buttons](/content/images/en/me-dialog-new.png)

From the top: title, the all-day switch, start and end, notes, category,
visibility and availability. Nothing is stored until you press **Save** at the
bottom.

| Field | Required | What it is |
| --- | --- | --- |
| Title | Conditionally | The event's name. Required when **Availability** is `Busy`; optional when it is `Available` |
| All day | — | Tick it and the event becomes a whole-day event with no time |
| Start / End | Required | The start and end of a timed event. Each is split into a **Date** field and a **Time** field |
| Start date / End date | Required | The start and end of an all-day event. The end date is part of the event |
| Notes | Optional | A note to yourself. It never reaches anyone holding a share link |
| Category | Optional | Used to colour the event. It never reaches anyone holding a share link |
| Visibility | Required | How much a share link may disclose |
| Availability | Required | Whether you can be reached at that time |

### When a title is required

An event whose **Availability** is `Busy` cannot be left without a title. An
unnamed event is usually one somebody stopped filling in halfway.

An event whose **Availability** is `Available` may have no title: "I am free
for these two hours" means something on its own. Left empty, the calendar
shows it as open time.

### Times and all-day events

![The top of the event dialog with the all-day box ticked, so start date and end date have become date-only fields (2026-10-21 and 2026-10-23) with no time](/content/images/en/me-allday.png)

A timed event takes a date and a time in **Start** and **End**. The end must
be at or after the start.

Ticking **All day** changes the fields to the date-only **Start date** and
**End date**. **The end date is included.** An all-day event from 21 to 23
October is a three-day event.

Which day an all-day event falls on is decided by the time zone in Settings,
which is why changing that setting changes how all-day events are read.

### Entering dates and times

Start and end each have a **Date** field and a **Time** field. The **Start
date** and **End date** of an all-day event, and a repeat's end date, are the
same kind of date field.

#### On a computer

Typing is the main way in.

- **Date**: type any of `20261019`, `2026-10-19` or `2026/10/19`; once confirmed it
  reads `2026-10-19`
- **Time**: type any of `1430`, `14:30`, `930` or `9:30`; once confirmed it reads
  `14:30` or `09:30`

Also:

- When you type a date as digits only, a hyphen is added after the four-digit
  year and the two-digit month (typing `2026` gives `2026-`). Typing the
  hyphen yourself does not double it. Deleting or changing characters in the
  middle, and pasting, work as usual
- While you type, the rest of the format (`-MM-DD`, `:mm` and so on) is shown
  faintly. It is a guide only and is not part of the value
- What you typed is confirmed when you Tab to the next field, press Enter or
  click outside the field, and is then tidied into the form above.
  Pressing Esc before that puts back the value you started with
- The up and down arrow keys move a date by one day, and a time by one on
  whichever side (hour or minute) the cursor is in
- Times use the 24-hour clock. Midnight is `00:00`

The calendar button (📅) beside a date opens a calendar, and the clock button
(🕒) beside a time opens a clock. Both are helpers that pick the same values
you could type.

![The calendar opened under the start date in the event dialog. An October 2026 title with previous and next arrows, dates starting on Monday, the selected 1st filled and today, the 19th, outlined, with Today and Cancel buttons below](/content/images/en/me-date-calendar.png)

| In the calendar | What it does |
| --- | --- |
| ‹ › | Move to the previous or next month |
| The title (October 2026 and so on) | Press it for a list of months, and again for a list of years, to jump there |
| Today | Move to the month containing today. No date is chosen |
| Pressing a date | Chooses it and closes the calendar |
| Cancel / Esc | Closes without changing anything |
| Keyboard | Arrow keys move a day, PageUp / PageDown a month, and with Shift a year; Enter chooses |

Weeks start on Monday. The calendar has no button that clears a date.

#### On a phone

Tap a date field and a calendar opens from the bottom of the screen; tap a
time field and a clock opens.

![Picking a time on a phone. Below the 09 : 00 readout is a 24-hour analog clock with 1 to 12 on the outer ring and 13 to 23 and 00 on the inner ring, and buttons to type instead, cancel and confirm](/content/images/en/me-time-clock.png)

| To | Do this |
| --- | --- |
| Choose the hour | Press or drag on the clock. The outer ring is 1 to 12, the inner ring 13 to 23 and 0. Lifting your finger moves on to the minutes |
| Choose the minutes | A press picks in five-minute steps, a drag in single minutes. −1 / +1 below adjust by one minute |
| Switch between hour and minutes | Press the `09` or `00` at the top |
| Type instead | Enter the hour and minutes as digits. The calendar also has **Type instead**, for typing a date as digits |
| OK | Sets the chosen time. In the calendar, pressing a date sets it |
| Cancel | Closes without changing anything |

#### Values that cannot be entered

Values like these are not changed into something else; they are refused. The
field turns red and the reason appears under it. The event cannot be saved
until you fix it.

| You type | Why |
| --- | --- |
| `20260230` (30 February) | That date does not exist |
| `24:00`, `25:00` | Hours run from 0 to 23. For midnight at the end of a day, use `00:00` on the next day |
| `14:78` | Minutes run from 00 to 59 |
| `9:5` | It could be 09:05 or 09:50. Type the minutes with two digits |

### Times across a daylight saving change

Where daylight saving time is observed, clocks jump forward and back twice a
year. Japan has no daylight saving time, so if you use Japanese time you will
not see this.

Times are handled in your device's (browser's) time zone. A notice appears
under the fields only when a start or end you enter falls on a change in that
time zone.

**A time that does not exist** (for example 2:30 on 8 March 2026 in New York:
clocks jump from 2:00 to 3:00, so 2:00 to 2:59 never happens)

"This time does not exist" is shown, with the times just before and after.
**It cannot be saved as it is.** Change the time. It is never moved to another
time for you.

**A time that happens twice** (for example 1:30 on 1 November 2026 in New York:
clocks go back from 2:00 to 1:00, so 1:00 to 1:59 happens twice)

**1st** and **2nd** are shown with their offset from UTC (for example
UTC−04:00 / UTC−05:00). Choose one, then save.

The one you choose is saved as that time. When you open the event again, the
same one is still chosen. Editing other fields without touching the time does
not change the event's time.

The notice concerns the start and end you enter for a timed event.

- All-day events are dates only and are not affected
- When a later occurrence of a repeating event falls on a change, its time is
  decided automatically by the repeat rule. You are not asked to choose

### Notes and category

Both are **for you alone**. Neither reaches anyone you give a share link to.
The category is used to colour the event on your own calendar.

### Visibility and availability

![Visibility and availability shown as two separate controls. Visibility is set to Private (private) and availability to Busy](/content/images/en/me-visibility-availability.png)

These are **two separate settings** and neither affects the other. As in the
picture, they are two adjacent controls; changing one leaves the other alone.

- **Visibility** is "how much may a share link disclose about this event"
- **Availability** is "can you be reached at that time"

All six combinations are valid. You can have an event whose visibility is
`Private (private)` while its availability is `Available` — meaning "I am free
then, but only tell the people I have let see private events".

What each combination shows is worked through in
[Visibility and open time](/en/docs/privacy-and-availability).

## Repeating events

The **Repeat** fieldset creates the same event at regular intervals.

| Field | What it takes |
| --- | --- |
| Frequency | Does not repeat / Daily / Weekly / Monthly |
| Interval | A whole number from 1 to 9999. Weekly with an interval of 2 is fortnightly |
| Days of the week | Chosen for a weekly repeat. Choosing none uses the start date's own weekday |
| Ends | Never / After a number of repeats / On a date |

![The repeat fieldset. Frequency is weekly, interval is 2, only Wednesday is selected, and it ends after a number of repeats set to 10](/content/images/en/me-recurrence.png)

The example above is "every second Wednesday, ten times".

The interval must be a whole number from 1 to 9999 and the number of repeats one from 1 to 9,999,999, and an end date cannot be left empty. A value outside these is not saved, and the reason is shown.

### A timed repeat and its time zone

A repeating event with a time repeats at **a fixed clock time**, so saving one
needs a time zone. If your browser cannot say what it is, this kind of event
cannot be saved; check your browser's date and time settings.

## Editing an event

Choosing an existing event opens the same dialog. On a phone, pressing an
event opens the full-screen editor.

### Editing an event on a phone

![Editing an event on a phone. It fills the screen: cancel, the title and save along the top; apply to, title, all day, start and end (a date and a time to tap for each), notes and category in the body; and delete at the bottom](/content/images/en/me-mobile-sheet.png)

| Where | What is there |
| --- | --- |
| Top | **Cancel** on the left, **Save** on the right |
| Body | The same fields as the dialog on a computer (apply to, title, all day, start and end, notes, category, visibility, availability, repeat). It scrolls |
| Bottom | **Delete** (when an existing event is open) |

If it cannot be saved, the reason appears in a red box. What you entered is
kept.

### Editing a repeating event

Opening a repeating event shows **Apply to** at the top.

![The scope selector at the top of the dialog when a recurring event is opened. It offers this occurrence only and all occurrences, with the first chosen](/content/images/en/me-scope.png)

| Choice | What changes |
| --- | --- |
| This occurrence only | Just the one you opened. The rest are left alone |
| All occurrences | The whole series |

**A series with an occurrence changed through "This occurrence only" cannot
then be changed through "All occurrences".** The individually changed ones
would be lost. It says so: "Some occurrences have been changed individually,
so the whole series cannot be edited".

For the same reason, a series with individually changed occurrences cannot
have its time zone changed either.

## Deleting an event

Press **Delete** in the dialog (on a phone, at the bottom of the editor). For a
repeating event the **Apply to** choice applies here too.

| Choice | What is deleted |
| --- | --- |
| This occurrence only | Just the one you opened. The rest stay |
| All occurrences | The whole series, including every individually changed occurrence |

Deleting all occurrences cannot be undone.

## Worth knowing

- Until a save finishes, what is on screen is still what the server holds. If
  a save fails, what you typed stays and the error is shown
- Deleting an event does not invalidate a share link you have already given
  out. To stop sharing, revoke the link itself
