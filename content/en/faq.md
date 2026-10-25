---
id: faq
lang: en
title: FAQ
sourceHash: 92a331c12d8dd04a
---

# FAQ

## Sharing

### Someone I shared with cannot see an event

Check its visibility.

| Visibility | Does it appear on a share link |
| --- | --- |
| Private (private) | Only when the link has "Include private events as busy" on |
| Busy only (busy_only) | Yes |
| Public (public) | Yes |

To disclose it while leaving it private, turn on **Include private events as
busy** on the **link**. You do not have to recreate the event, but **that
setting cannot be changed afterwards**. Create a new link.

Check the period too. They are looking at one week at a time. Make sure the
event is in that week.

### Can someone I share with see an event's name

No. An event's name, notes and category **never reach them, under any
setting.**

Setting visibility to public does not hand over contents. Visibility decides
whether a time range is included in sharing.

### Open time (Available) is not showing

Check these in order.

| Check | What to look at |
| --- | --- |
| 1 | Did you set the event's **Availability** to **Available**? |
| 2 | Did you turn on "Also share events marked as open time" on the share link? |
| 3 | If the event is **private**, is "Include private events" on **as well**? |
| 4 | Is a `Busy` event overlapping the same time? |
| 5 | Does a monthly repeating event touch that period? |

For 2, an active link can be switched afterwards. For 3, the link has to be
recreated.

For 4, **busy wins**. Overlapping time is not shown as open.

### Does time with no event become open time

No. The only time shown as open is time you **explicitly recorded as open
time**.

Time with no event in it is never published as open automatically.

### It says "Open time could not be determined for this period"

That **does not mean there is no open time.** It means it could not be worked
out.

Here is what you can check on your side.

| Check | What to do |
| --- | --- |
| Is there a monthly repeating event in that period | Monthly repeats currently cannot be expanded on the server |
| Does the timed repeating event have a settled time zone | Set one |
| Are an all-day event and a timed event in the same period while the calendar time zone is unset | Set one |
| Are there a very large number of occurrences in that period | Split the period, or tidy up the repeat |

### It says "No open time is shared for this period"

This one is a result the calculation **reached**. It was confirmed there is no
open time to disclose.

How it differs from "could not be determined" is in
[What people you share with see](/en/docs/what-viewers-see).

### Someone says the share link does not work

They are not told why. Check the link's state under **Existing links** on your
side.

| State | What to do |
| --- | --- |
| Expired | Create a new link |
| Revoked | Create a new link |
| Active | Check that the URL reached them intact |

### I have lost a share link's URL

**It cannot be shown again.** The URL appears only when the link is created,
and the token is not stored.

Revoke that link and create a new one.

### If I delete an event, does the share link stop working

No. To stop sharing, **revoke the link.**

### I cannot create a share link

| Message | What to do |
| --- | --- |
| You have reached the limit for active share links | Revoke a link you do not need (the limit is 25) |
| You have reached the limit for share links in total | **Delete a revoked link** (the limit is 200) |
| Creating share links is temporarily limited | Wait for the time shown |

**Revoking alone does not reduce the total.** Freeing a slot in the total
needs a delete.

## Dates and times

### My times do not line up with the other person's

Their screen is shown in **their browser's time zone**. It is the same moment
expressed in their time, so a different display is normal.

### An all-day event looks a day out

An all-day event is treated as a calendar day in **the calendar time zone you
set**. When that differs from your browser's time zone, it looks shifted.

Check the setting. [Time zones](/en/docs/time-zones) has the details.

### Does changing the time zone move my events

**Timed events do not move.** What changes is which calendar day an all-day
event falls on, and how open time appears on the anonymous share page.

### A date or time field turns red

What you typed cannot be read as a date or time. The reason appears under the
field.

- **Date**: `20261019`, `2026-10-19` or `2026/10/19`
- **Time**: `1430`, `14:30`, `930` or `9:30` (24-hour clock)

A date that does not exist (30 February, for example) or a time such as
`24:00` or `14:78` is refused rather than changed into something else. While a
field is red the event cannot be saved. Before it is confirmed, Esc puts back
the value you started with.

### It says "This time does not exist"

You entered a time that clocks skip when daylight saving time begins. It cannot
be saved, so change the time. It is never moved to another time for you.
[Events](/en/docs/managing-events) has the details.

### It asks me to choose the 1st or the 2nd

You entered a time that happens twice when clocks go back at the end of
daylight saving time. Look at the offset from UTC, choose one, then save. Your
choice is saved and stays the same when you reopen the event.

### It says "This time zone cannot be used"

The server cannot handle the time-zone name your browser reported. Check your
browser's date and time settings.

### A timed repeating event will not save

If it says a time zone could not be determined, so a repeating event with a
time cannot be saved, then your browser is not reporting one. Check your
browser's date and time settings.

## On a phone

### I cannot find Settings or Sign out

On a narrow screen (less than 720px wide), **Settings**, **User guide** and
**Sign out** are inside the menu (☰) at the top right. Switching the theme
stays outside the menu.

### There is no month, week or day view

A phone has two views, **Agenda** and **Month**.
[Getting started](/en/docs/getting-started) explains them.

## Language

### Their screen is in English

Because their browser is in English. **Your language setting does not affect
their screen.**

### Does changing the language change what is shared

No. Only the words on screen change.

### My language setting will not save

If a save fails, **the display language does not change.** What you selected
stays in the control, so press **Save** again.

### The guide is not in English

The guide's language is **decided by the URL**. Open `/en/docs/...`. The
language switch on each guide page moves there too.

For a chapter that has not been translated, an English URL shows the Japanese
text with a notice saying so.

## Repeating events

### I cannot choose yearly

Only daily, weekly and monthly are available.

### I cannot say "the second Monday of the month"

Ordinal weekdays are not available. Weekdays can be chosen only for a weekly
repeat.

### A monthly event on the 31st is missing in some months

A month that has no such day is **skipped**. It does not fall back to the
30th.

### I cannot change "All occurrences"

If it says some occurrences have been changed individually so the whole series
cannot be edited, then that series has an occurrence changed through "This
occurrence only".

An individually changed occurrence is stored as **a copy of its contents at
that moment**, and changing the rule leaves it meaningless. Tidy up the
individual changes, then change the whole series.

### I cannot change a repeat's time zone

The same reason. A series with individually changed occurrences cannot have
its time zone changed either.

### It says this repeating event has reached its limit for per-occurrence changes

There is a limit on how many individual changes one repeating event may hold.
Tidy up the ones you do not need.

## Saving

### An event will not save

| Message | What to do |
| --- | --- |
| Please enter a title | The conditions that require a title are not met |
| You have reached the limit for stored events | Delete events you do not need |
| Saving is temporarily limited | Wait for the time shown |
| A length limit | Shorten the field it names |

### If a save fails, do I lose what I typed

No. What you typed stays, and the error is shown. The values on screen are
still **what the server holds**.

## What to read next

| Chapter | About |
| --- | --- |
| [Getting started](/en/docs/getting-started) | The settings to check first |
| [Visibility and open time](/en/docs/privacy-and-availability) | Visibility and availability together |
| [What people you share with see](/en/docs/what-viewers-see) | What appears on their screen |
