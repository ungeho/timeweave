---
id: privacy-and-availability
lang: en
title: Visibility and open time
sourceHash: 0d2c722d0c678eac
---

# Visibility and open time

What someone you give a share link to can and cannot see.
**If you read only one chapter before sharing, read this one.**

## The most important thing first

A share link gives the other person **time ranges, and nothing else**.

**An event's title, notes and category never reach them, whichever visibility
you choose.** Choosing `Public (public)` does not make the event's name
visible.

There are only three things they see.

![What someone opening a share link sees. Each day shows time ranges only, with busy blocks and open-time blocks drawn differently. No event name appears anywhere](/content/images/en/pa-viewer-complete.png)

That is the actual screen a share link opens. Each day holds time ranges only,
and **no event name appears anywhere.** A filled block is busy, a hatched
block is open time. A day you have disclosed nothing about shows "—".

| On their screen | What it means |
| --- | --- |
| Busy | There is an event in that time range |
| Open | A time range you marked as one you can be reached in |
| — | You have disclosed nothing about that day |

## Two settings, two different questions

An event has a **Visibility** setting and an **Availability** setting. **They
are independent, and neither decides the other.**

| Setting | The question it answers |
| --- | --- |
| Visibility | **May a share link disclose** this event |
| Availability | **Can you be reached** at that time |

### The three visibility values

| Value | What it means |
| --- | --- |
| Private (private) | An event for you alone. Disclosed only to a share link set to include private events |
| Busy only (busy_only) | An event whose existence may be disclosed |
| Public (public) | An event whose existence may be disclosed |

As far as a share link is concerned, the only thing that makes a difference is
**whether the event is `Private (private)`**. `Busy only (busy_only)` and
`Public (public)` are treated identically by a share link, and neither hands
over a title. What differs between those two today is **how they look on your
own calendar** — the icon and a short label.

### The two availability values

| Value | What it means |
| --- | --- |
| `Busy` | There is an event then, and you cannot be reached |
| `Available` | Time you decided, and recorded, that you can be reached in |

On the share dialog and the share page these are the words used too. The
viewer's own screen labels an `Available` block as **Open**.

## Time with no event does not become open time

This is the easiest thing to get wrong.

**The only open time anyone is told about is time you recorded as
`Available`.** Time with no event in it is never published as open
automatically.

So the empty parts of your calendar show the other person nothing at all. A
gap in a schedule is not treated as "free".

It holds the other way round as well: time that is NOT shown on their screen
is not necessarily free. You may simply not have disclosed it. The share page
says so too.

## Busy wins over Available

Suppose a `Busy` event later overlaps time you recorded as `Available`. **The
overlapping part is removed from the open time.**

Example: 14:00–17:00 recorded as `Available`, with a `Busy` meeting from
15:00 to 16:00.

| Time range | What they see |
| --- | --- |
| 14:00–15:00 | Open |
| 15:00–16:00 | Busy |
| 16:00–17:00 | Open |

`Available` never cancels out `Busy`. `Busy` always wins.

## A share link's two permissions

Creating a share link offers two checkboxes. **They are independent
permissions, and neither covers the other.**

| Checkbox | What it permits |
| --- | --- |
| Include private events as busy | Include `Private (private)` events in what this link covers |
| Also share events marked as open time (Available) | Tell this link's holder about open time |

### A private event marked Available needs both

This is the combination people get wrong most often.

To show someone an event whose visibility is `Private (private)` and whose
availability is `Available`, **both checkboxes have to be ticked.** Sharing
open time alone does not disclose it.

### The combinations at a glance

The event's settings (down) against the share link's settings (across), and
what the other person sees.

| Event visibility | Availability | Include private | Share open time | What they see |
| --- | --- | --- | --- | --- |
| Private (private) | `Busy` | OFF | — | Nothing |
| Private (private) | `Busy` | ON | — | Busy |
| Busy only / Public | `Busy` | — | — | Busy |
| Private (private) | `Available` | OFF | ON | **Nothing** |
| Private (private) | `Available` | ON | OFF | Nothing |
| Private (private) | `Available` | ON | ON | Open |
| Busy only / Public | `Available` | — | OFF | Nothing |
| Busy only / Public | `Available` | — | ON | Open |

Even where it says Busy, no title is handed over.

## The three states their screen can be in

For open time, one of these appears depending on the situation. **The three
mean completely different things.**

| State | Their screen | What it means |
| --- | --- | --- |
| Not requested | Nothing is shown | This link is not set to tell them about open time. Nobody asked the question |
| Indeterminate | "Open time could not be determined for this period." | **It does not mean there is no open time.** It means it could not be worked out |
| Complete | Open blocks, or "No open time is shared for this period." | It was worked out exactly |

### "Could not be determined" is not "not free"

This distinction matters more than any other here.

When the screen says open time could not be determined for the period, that
means **it could not be worked out** — not that **there is no open time**.
When this appears, ask the person to get in touch with you directly to check.
The share page tells them so.

In the same way, "No open time is shared for this period" means **no open time
is being shared**. It does not mean you have none. You may simply not have
recorded any.

### When it cannot be worked out

When the same period holds both an **all-day event** and **timed open time**,
there is no way to calculate which overlaps which until a time zone is known.

**Setting a time zone in Settings makes this case calculable.** Left unset,
the safe behaviour is to show no open time at all.

That is why [Getting started](/en/docs/getting-started) asks you to check the
time zone first.

## Stopping a share

| Action | Result |
| --- | --- |
| Revoke | The URL stops working. The record stays |
| Delete | Removes the record of a revoked link. It cannot be undone |

**The URL of a link you have already created cannot be looked up again.** It
is shown once, just after it is created. If you lose it, revoke the link and
create a new one.

Deleting an event does not invalidate a share link you have already given out.
To stop sharing, revoke the link itself.
