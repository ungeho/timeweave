---
id: what-viewers-see
lang: en
title: What people you share with see
sourceHash: d7ae64cc776007d3
---

# What people you share with see

Opening a share link gives the other person a read-only screen of its own.
This chapter is about **what appears on it and what does not**.

They do not sign in. They do not need an account.

## What does not appear

| Never reaches them |
| --- |
| The event's name |
| Notes |
| Category |
| The visibility (whether it is private, busy_only or public) |
| How many events there are |
| Your email address or name |

**Setting visibility to public does not hand over an event's contents.**
Visibility decides whether an event's time range may be included in sharing.
It is not a setting that shows contents.

What reaches them is **time ranges, and nothing else**.

## What does appear

The screen holds a week, with time ranges under each day. **This week**,
**Previous week** and **Next week** move the period.

| On screen | What it means |
| --- | --- |
| Busy | There is an event at that time |
| All day — busy | There is an all-day event that day |
| Open | Time the owner **recorded as open time** |
| All day — open | That day is recorded as open time for the whole day |

Busy and open blocks are drawn as a fill and a hatch. They do not rely on
colour alone, so they stay distinguishable in greyscale. Each block also
carries the words "Busy" or "Open" next to its time.

Above the week, "How to read this" is always shown. It says what each kind of
block means and that **time with nothing shown is not necessarily free**. On a
link that does not share open time, only the busy entry is listed. A day with
nothing shown has a dash.

A note at the bottom of the screen always says what is being shared. It
changes to a longer sentence when open time is on screen.

## Do not misread "open"

**Time that is not shown as open is not necessarily free.**

An open block appears only when the owner explicitly recorded an event as open
time AND the share link permits disclosing it. Time with no event in it is
never shown as open automatically.

The note at the bottom of the screen says the same.

## The three states open time can be in

For open time, **one of three answers** comes back, and each gives the other
person a different screen.

| State | What they see | What it means |
| --- | --- | --- |
| Determined (open time exists) | Open blocks | The open time for the period was worked out exactly |
| Determined (none) | No open time is shared for this period | Worked out exactly, and there was no open time to disclose |
| **Could not be determined** | Open time could not be determined for this period | It could not be worked out |

A link that does not share open time shows nothing about open time at all.
That does not mean there is none either.

### "Could not be determined" is not "not free"

This is the most easily misread message on the screen.

**It reports an absence of knowledge, not an absence of open time.**

![What someone opening a share link sees. A warning at the top says open time could not be determined, and below it only busy blocks are drawn. No open-time block appears](/content/images/en/pa-viewer-indeterminate.png)

The screen goes on: "Please get in touch directly to check availability." It
is telling them that checking is needed.

On this screen **not a single open block appears**. Busy blocks do, but the
gaps between them do not mean the owner is free.

### How it differs from "none"

| Message | Calculation | What it means |
| --- | --- | --- |
| No open time is shared for this period | **Succeeded** | It was confirmed there is no open time to disclose |
| Open time could not be determined for this period | **Failed** | Unknown |

![What someone opening a share link sees. A notice at the top says no open time is shared for this period, and busy blocks are drawn below it](/content/images/en/pa-viewer-empty.png)

They look very similar, but **the sentence in the banner differs.** This one
says the calculation succeeded, and appears as a notice rather than a warning.

"None" also means no open time is **being shared**. It does not mean the owner
is not free.

### When it cannot be determined

| Cause |
| --- |
| A monthly repeating event touches the period |
| A timed repeating event has no settled time zone |
| An all-day event and a timed event share a period while the owner has no time zone set |
| There are too many occurrences in the period |
| A repeat rule the server cannot handle is stored |

What the owner can check is in the [FAQ](/en/docs/faq).

## Busy wins

When busy and open overlap at the same time, **busy wins.** That time is not
shown as open.

Being told "there is an event" is safer than being wrongly told "it is free".

![One day from what someone opening a share link sees. 15:00 to 16:00 is a filled busy block, while 14:00 to 15:00 and 16:00 to 17:00 are hatched open-time blocks, drawn differently from it](/content/images/en/pa-busy-wins.png)

Above, the owner recorded 14:00 to 17:00 as open time and has an event from
15:00 to 16:00 inside it. The overlapping hour is **removed from the open
time**, leaving 14:00–15:00 and 16:00–17:00 as the open blocks.

**The blocks are not in time order.** The busy ones come first as a group,
then the open ones. Each block carries its own times; read them there.

## A period containing repeats that could not be included

When a period holds a repeating event that cannot be expanded exactly, this
warning appears:

> Some repeating events in this period could not be included. Times not shown
> are not necessarily free.

While that warning is showing, **the busy blocks on screen are not
necessarily all of them.**

## When a link does not work

When a link does not work, the other person gets a single sentence.

> This share link is not available.

![What someone opening a share link sees. A single line says the share link is not available; no week navigation and no calendar grid appear](/content/images/en/wvs-unavailable.png)

**No reason is given.** Expired, revoked, deleted, a URL that never existed
and a malformed URL all produce the same screen, so that nobody can work out
from the outside which link is in which state.

There is no week navigation and no calendar grid. **They cannot change the
period and look again either.**

## When nothing is shared for the period

> No events are shared for this period.

This means **there is nothing in that period to share**. It does not mean the
owner has no events. The visibility settings may be keeping them out of what
is shared.

## When loading fails

> Free/busy could not be loaded. Please wait a moment and reload.
> (this screen does not mean “no events”)

The sentence at the end is there to stop an error screen being read as "no
events".

Loading can also fail temporarily when too many requests arrive at once.

## The language of their screen

Their screen is shown in **their own browser's language**. The owner's
language setting is not used; the share page does not even fetch it.

[Language](/en/docs/language) goes into this.

## What to read next

| Chapter | About |
| --- | --- |
| [Share links](/en/docs/share-links) | Creating and managing a link |
| [Visibility and open time](/en/docs/privacy-and-availability) | Visibility and availability together |
| [FAQ](/en/docs/faq) | What to check when something is not shown |
