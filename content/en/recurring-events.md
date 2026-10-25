---
id: recurring-events
lang: en
title: Repeating events
sourceHash: fc9598641261d758
---

# Repeating events

Creating and editing one is covered in [Events](/en/docs/managing-events).
This chapter is about **how a repeating event differs from a one-off** and the
limits worth knowing before you hit them.

## How it differs from a one-off

A one-off is a single event. A repeating event is **one "base" event plus a
rule**. The dozens of occurrences you see on screen are worked out from that
rule each time.

That construction decides the following.

| | One-off | Repeating |
| --- | --- | --- |
| What is stored | Just that event | The base event + the rule (+ any individually changed occurrences) |
| Changing one occurrence | Changes that event | **Adds one "individually changed occurrence"** |
| Changing the whole thing | — | Changes the base event |
| A limit on how many | — | Worked out from the rule, so nothing more is stored |

Choosing "Never" as the end does not store thousands of events. Only the
period on screen is worked out.

## The rules you can express

| Field | What it takes |
| --- | --- |
| Frequency | Daily, weekly or monthly |
| Interval | A whole number from 1 to 9999 |
| Days of the week | **Weekly only.** Several may be chosen |
| Ends | Never, after a number of repeats, or on a date |

Saving a weekly repeat with no weekday chosen uses **the start date's own
weekday**. The weekday used is the one the start date falls on in the
calendar's time zone.

### What it cannot express

These have no field on screen. That means they **cannot be done**.

| What you might want | Today |
| --- | --- |
| Yearly | Not available |
| An ordinal weekday such as "the second Monday of the month" | Not available |
| A day of the month such as "the 15th and the last day" | Not available |
| Choosing weekdays for a monthly repeat | Weekly only |
| Both a number of repeats and an end date | One or the other |

If a rule brought in from another calendar goes beyond this range, TimeWeave
does not guess at what it means. Such a repeating event is left off the
calendar, and a notice at the top says how many repeating events cannot be
shown. Your other events are shown as usual.

## How a monthly repeat picks its date

A monthly repeat falls on **the same day of the month as the base event**. An
interval of 2 makes it every second month.

A month that has no such day is **skipped**. A monthly event created on the
31st does not appear in February, April, June, September or November. It does
not fall back to the 30th.

To repeat on the last day of each month, you currently have to create a
separate event for each date.

## Setting an end

| Choice | What it means |
| --- | --- |
| Never | It does not end |
| After a number of repeats | It ends after exactly that many (1 to 9,999,999) |
| On a date | It repeats up to that date. **The end date is included** |

The end date is handled differently for all-day and timed events.

- **An all-day event**: treated as a calendar date. No time-zone conversion
  happens.
- **A timed event**: treated as the end of that day (23:59:59.999 in the
  calendar's time zone).

## Individually changed occurrences

Changing a single occurrence through "This occurrence only" stores that
occurrence separately, as **a copy of its contents at that moment**. Deleting
a single occurrence also leaves a record saying "this one is not there".

Two things follow, and both appear as a refused operation.

| What happens | What it says |
| --- | --- |
| A series with individually changed occurrences cannot be changed through "All occurrences" | Some occurrences have been changed individually, so the whole series cannot be edited |
| For the same reason, the series' time zone cannot be changed either | Some occurrences have been changed individually, so the time zone of the series cannot be changed |

**A copy is not worked out from the rule, so changing the rule leaves it
meaningless.** TimeWeave refuses the operation rather than discarding the copy
silently.

Once you have tidied up the individually changed occurrences, the whole series
can be changed. There is also a limit on how many such changes one series may
hold; past it, you get "This repeating event has reached its limit for
per-occurrence changes. Tidy those changes and try again".

## The time zone is part of the rule

A repeating event with a time repeats at **a fixed clock time**. "9am every
morning" means nothing until it is settled which time zone's 9am that is.

So saving a timed repeating event needs a time zone. If your browser cannot
say what it is, this kind of event cannot be saved.

Changing the series' time zone **moves every occurrence to a different
moment**. Renaming an event never rewrites its time zone; changing the time
zone is a separate operation.

[Time zones](/en/docs/time-zones) goes into this.

## Occurrences on a daylight-saving changeover

Each occurrence of a timed repeating event is placed at the same clock time in
the series' time zone. If that zone has daylight saving time, the changeover
days work as below. Unlike entering a single event (see "Daylight saving
changes and the times you enter" in [Time zones](/en/docs/time-zones)), **the
occurrences are placed automatically, and you are not asked.**

| The time on that day | Where the occurrence goes | Example: every Sunday, America/New_York |
| --- | --- | --- |
| A time that does not exist (clocks jump ahead) | Later by the size of the jump. The occurrence is never dropped | A 2:30 event is at 3:30 on March 8, 2026 only |
| A time that happens twice (clocks fall back) | At the **second** of the two. Never at the first | A 1:30 event is at the 1:30 after the clocks went back on November 1, 2026 |

Where the clocks jump across midnight, an occurrence can move to **the next
day**. In Greenland's America/Nuuk, 23:00 to 23:59 on Saturday, March 28, 2026
does not exist, so a weekly Saturday 23:30 event is at **0:30 on Sunday,
March 29** that week only.

A share page shows "Busy" at the same time. To put that one occurrence at a
different time, edit it with "This occurrence only".

An older repeating event whose time zone is "Not set" does not follow this
rule: its occurrences follow the device's clock (a time that happens twice
takes the first), and a share page cannot determine open time for the periods
it covers. Open the event and press "Set the current time zone (…)" under
"Time zone" to have it follow the rule above. This is not possible for a series
with individually changed occurrences.

## What this does to sharing

This is the part that is easy to miss.

**When a monthly repeating event touches a period you are sharing, open time
on the other person's screen becomes "could not be determined".**

Open time on a share page is calculated only when the server can expand the
repeats exactly. Daily and weekly can be expanded, but **monthly currently
cannot be, on the server side**. Rather than guessing at a period it cannot
count exactly, the design is to say it could not be determined.

The following produce the same result.

| Cause | Result |
| --- | --- |
| A monthly repeat touches the period | Open time cannot be determined |
| A timed repeat has no settled time zone | The same |
| There are too many occurrences in the period (past the expansion limit) | The same |
| A rule the server cannot handle is stored | The same |

"Could not be determined" **does not mean there is no open time**.
[What people you share with see](/en/docs/what-viewers-see) explains it.

## What to read next

| Chapter | About |
| --- | --- |
| [Time zones](/en/docs/time-zones) | A series' time zone, and all-day events |
| [What people you share with see](/en/docs/what-viewers-see) | What "could not be determined" means |
| [FAQ](/en/docs/faq) | Questions about what a repeat can and cannot do |
