---
id: time-zones
lang: en
title: Time zones
sourceHash: b4d8cf46dcbca266
---

# Time zones

Time zones come into TimeWeave in three places. They are easy to mix up, so
each is taken separately.

| Where | Which time zone is used |
| --- | --- |
| Times on your own screen, and the times you enter for events | Your browser's (device's) time zone |
| Which day an all-day event falls on | **The calendar time zone you set** |
| The screen of someone you share with | Their browser's time zone |

**To enter an event at another region's time, convert it to this device's time
first.** There is no per-event time zone. For example, to add a 9:00 a.m. New
York meeting (winter time) from a device set to Japan, enter 23:00 Japan time.
What is saved is that moment, so a device in New York shows it at 9:00.

## What the calendar time zone decides

**Time zone** in Settings decides **which calendar day an all-day event is
treated as**.

"An all-day event on 13 October" is not fixed as a moment until it is settled
which time zone's 13 October it is. This setting is that reference.

Leaving it empty returns it to **not set**. Empty is not "no value"; it is a
state of its own.

### It works the opposite way round from language

The asymmetry is deliberate.

| | Whose it is | Why |
| --- | --- | --- |
| Time zone | **The owner's** | An all-day event means a day in the owner's calendar. Letting the other side decide would let them move the day boundary |
| Language | **The reader's** | So nobody is handed a screen in a language they cannot read |

## What changes when you change it

A confirmation appears only for a change that moves the day boundary. It shows
three lines.

| What changes |
| --- |
| All-day events are read as calendar days in this time zone |
| The open time shown on the anonymous share page may change |
| **Events with a start and end time do not move** |

The third line matters. **Timed events do not move.** A 2pm meeting is still
at 2pm. What moves is how all-day events are read.

## What happens if you leave it unset

Everyday use works with it unset. It affects sharing, though.

Settings shows this notice:

![The settings dialog with an empty time-zone field and a notice saying that when a period holds both all-day events and timed open time, the anonymous share page cannot show open time](/content/images/en/tz-unset-notice.png)

> No time zone is set, so when a period contains both all-day events and timed
> open time, the anonymous share page cannot show open time (it is hidden to
> stay safe).

### Why it cannot be shown

An all-day event is "a day in a calendar"; a timed event is "a moment". When
both are in the same period, deciding which comes first needs **a reference
for converting a calendar day into a moment**. With no time zone set, there is
no such reference.

Rather than guessing and telling somebody "this is free", the choice is not to
show open time. In this case their screen says open time could not be
determined.

**If you use both all-day and timed events and you share open time, set a time
zone.**

## A repeating event's time zone

A repeating event with a time carries **a time zone of its own**, separate
from the calendar setting.

"9am every morning" has no settled meaning as a repeat until it is clear which
time zone's 9am it is. If your browser cannot say what it is when you save,
this kind of event cannot be saved.

Changing a series' time zone **moves every occurrence to a different moment**.
That is why it is a separate operation, and why renaming an event never
rewrites it. It cannot be changed on a series with individually changed
occurrences.

[Repeating events](/en/docs/recurring-events) goes into this.

## Daylight saving changes and the times you enter

The start and end you enter for an event are read as times in your browser's
(device's) time zone. If that time zone has daylight saving time, a change day
has these times:

| Time | In the event dialog |
| --- | --- |
| A time that does not exist (while clocks jump forward) | It cannot be saved. Change the time |
| A time that happens twice (while clocks go back) | Choose the 1st or the 2nd, then save. Your choice is saved and stays the same when you reopen the event |

Japan has no daylight saving time, so neither happens if you use Japanese
time. For the details, see [Events](/en/docs/managing-events).

## Times on their screen

Someone opening a share link sees the times in **their own browser's time
zone**.

So the same share link opened in another country **shows different times**.
That is intended: times that mean something where the reader is are more
useful.

| | Your screen | Their screen |
| --- | --- | --- |
| How times are shown | Your browser | Their browser |
| The reference for an all-day event's date | The calendar time zone you set | **The same** (your setting) |

Which day an all-day event falls on is decided by your setting and does not
move on their side.

## What to check when a date looks wrong

### An all-day event is on the wrong day on your own screen

1. Check the time zone in Settings
2. Check whether it differs from your browser's time zone
3. If it does, all-day events are being treated as calendar days in **the one
   you set**

An event whose date differs between your browser's time zone and the one you
set will look shifted. Decide which you want and make the setting match.

### Your times do not line up with the other person's

A timed event is shown in their browser's time zone. It is not shifted; it is
**the same moment expressed in their time**.

When checking, the reliable approach is to state both time zones explicitly.

### An all-day event appears a day early or late on their screen

An all-day event is treated as a calendar day in the owner's calendar time
zone. When their time zone is far from it, it can look as though it spans the
day before or after on their clock.

This is not a conversion error. It is what "the owner's 13 October" looks like
expressed in their time.

### It says the time zone cannot be used

"This time zone cannot be used. Please check your browser's date and time
settings" means the server cannot handle the time-zone name your browser
reported. Check your browser's date and time settings.

## What to read next

| Chapter | About |
| --- | --- |
| [Repeating events](/en/docs/recurring-events) | A series' own time zone |
| [What people you share with see](/en/docs/what-viewers-see) | What appears when it cannot be determined |
| [FAQ](/en/docs/faq) | Questions about dates and times |
