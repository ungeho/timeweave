---
id: share-links
lang: en
title: Share links
sourceHash: efe4e7f953a5f54c
---

# Share links

**Before this chapter, please read
[Visibility and open time](/en/docs/privacy-and-availability).** What actually
reaches the other person is explained there. This chapter is about creating
and managing the links themselves.

## Creating a link

Press **Share** above the calendar on a computer, or **Share** under the
header on a phone, and **Share your free/busy** opens. The creation form has
four fields.

![The share-link creation form, with a label field, a checkbox for including private events as busy (on by default), a checkbox for also sharing events marked as open time (off by default), the note beneath them, an expiry field and a create button](/content/images/en/pa-share-dialog.png)

| Field | Required | Starts as |
| --- | --- | --- |
| Label | Optional | Empty. **A note to yourself.** The other person never sees it. Up to 50 characters |
| Include private events as busy | Optional | **On** |
| Also share events marked as open time (Available) | Optional | Off |
| Expiry | Optional | Empty. Left empty, the link does not expire |

The expiry field is your browser's own date and time control. It works
differently from the event dialog's date and time fields.

### How the expiry works

- You enter it in **this device's time zone**.
- Leave it empty and the link does not expire.
- A time before now cannot be set. "Choose a future date and time for the
  expiry" appears and no link is created.
- A **time that does not exist** because of a daylight saving switch (2:30 on
  a day the clocks jump from 2:00 to 3:00, for example) cannot be set. The
  reason is shown.
- A **time that happens twice** as daylight saving ends (1:30 on a day 1:00 to
  1:59 happens twice, for example) shows a choice of "1st" and "2nd", each with
  its offset from UTC. The link cannot be created until you choose one.
- The URL stops working at the expiry time.

**The first checkbox is on from the start.** Create the link as it stands and
the time ranges of your private events are disclosed as busy. Turn it off
before creating the link if you do not want that. **This setting cannot be
changed afterwards.**

Pressing **Create link** shows the URL.

### Creating a link on a phone

![Sharing on a phone. It fills the screen, with the share title and a close button along the top, then the label, the two checkboxes, the note, the expiry and the create button](/content/images/en/sl-mobile-share.png)

On a phone the sharing view fills the screen. The fields and what they do are
the same as on a computer. Scroll below the creation form for the list of
existing links. To close it, press **Close** at the top right.

### The URL is shown only when the link is created

![What appears right after a share link is created: the URL in a field with a copy button, followed by the warning that this URL is shown only once and cannot be shown again after closing](/content/images/en/sl-created-url.png)

**Close this and the same URL can never be shown again.** The token is not
stored.

Copy it before closing and give it to the other person if you need it. If you
lose it, the only way forward is to revoke that link and create a new one.

## What the two checkboxes decide

The two permit **different things**. Confusing them leads to disclosing more
than you meant to.

| Checkbox | What it permits |
| --- | --- |
| Include private events as busy | Counts the **time ranges** of private events as busy |
| Also share events marked as open time (Available) | Shows the other person events recorded as open time |

Whichever you turn on, **an event's name, notes and category never reach
them.**

### A private event marked as open time needs both

To show someone an event whose visibility is private and whose availability is
`Available`, **both checkboxes have to be on.**

One alone is not enough.

| Include private | Share open time | A private + `Available` event |
| --- | --- | --- |
| Off | Off | Does not appear |
| **On** | Off | Does not appear |
| Off | **On** | Does not appear |
| **On** | **On** | Appears as open time |

The whole picture is in the table in
[Visibility and open time](/en/docs/privacy-and-availability).

### Open time is not "time with no event in it"

The same warning appears under the checkboxes.

What is disclosed is **only time you explicitly recorded as open time**. Time
with no event in it is never published as open automatically.

## Managing the links you have made

**Existing links** lists them. Each one shows its state and the settings it
was created with.

![The list of existing share links. Each row shows a label, whether it is active, expired or revoked, and a summary of whether private events are included and open time is shared. Active rows carry a revoke button and an open-time toggle; only the revoked row offers delete; the expired row says to revoke it first](/content/images/en/sl-link-list.png)

| State | What it means |
| --- | --- |
| Active | It works |
| Expired | It is past its expiry. The URL does not work |
| Revoked | You revoked it. The URL does not work |

The settings appear on each row as "private included" / "private excluded",
"open time shared" / "open time not shared", and "expires …". The expiry is
followed by its offset from UTC at that time (UTC+09:00, for example), so even
when a daylight saving switch makes a time happen twice you can tell which one
the link expires at.

### Sharing open time can be changed later

An active link carries a **Share open time (Available)** toggle. **You can
turn it on or off afterwards without recreating the link.**

It cannot be changed on an expired or revoked link. Trying says "This link’s
setting could not be changed. It may be expired or revoked. The list has been
refreshed."

The label, whether private events are included, and the expiry cannot be
changed afterwards. To change those, create a new link.

## Stopping a link from working

**Revoking** and **deleting** are different operations.

| Operation | What happens | Applies to |
| --- | --- | --- |
| Revoke | The URL stops working. **The record stays** | An active link |
| Delete | Removes the record itself. **It cannot be undone** | **A revoked link only** |

An expired link cannot be deleted straight away. It says "Expired but not
revoked. To delete it, revoke it first." Revoke it, then delete it.

### Why two steps

There is a limit on how many share links you may have.

| Limit | Number |
| --- | --- |
| Active links | 25 |
| Link records in total | 200 |

**Revoking alone does not reduce the total.** Revoking stops a link working
while keeping its record. To free up room in the total, delete the revoked
links.

At each limit it says:

- The active limit: revoke a link you no longer need and try again
- The total limit: deleting a revoked link frees a slot (revoking alone does
  not reduce the total)

## Deleting an event leaves the link alone

Deleting an event does not invalidate a share link you have already given out.
To stop sharing, **revoke the link.**

## When creating links is refused

Creating several in quick succession is temporarily limited. It says "Creating
share links is temporarily limited after too many at once" and tells you
roughly how long to wait.

## What to read next

| Chapter | About |
| --- | --- |
| [What people you share with see](/en/docs/what-viewers-see) | What your link actually opens |
| [Visibility and open time](/en/docs/privacy-and-availability) | Visibility and availability together |
| [FAQ](/en/docs/faq) | Questions about sharing |
