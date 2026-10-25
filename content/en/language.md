---
id: language
lang: en
title: Language
sourceHash: eb7e13a1ca0fcc89
---

# Language

TimeWeave is available in Japanese and English.

## Setting it

Choose under **Display language** in Settings.

| Choice | What it does |
| --- | --- |
| Follow browser setting | Decides from your browser's language (the starting state) |
| 日本語 | Shows Japanese |
| English | Shows English |

Press **Save** to store it. The language you chose is used again the next time
you sign in.

## How the display language is decided

These are tried in order, and **the first one that applies wins**.

| Order | Condition |
| --- | --- |
| 1 | There is a stored choice (Japanese / English) |
| 2 | Your browser's languages include one that is supported |
| 3 | Neither → Japanese |

### How the browser's language is read

The list of languages your browser reports is examined **from the top**. The
first supported language found is used.

If your first preference is French and your second is English, you get
**English**. An unsupported language does not stop the search.

Regions are ignored. `en-US`, `en-GB` and `EN` are all treated as English.

## Screens you see without signing in

The sign-in page and the share page have no stored setting. There,
**the browser's language** is used (the second row above).

## The language of a share page

**Someone opening a share link sees it in their own browser's language.**

The owner's language setting is not used. The share page **does not even
fetch** the owner's setting.

| | Which language |
| --- | --- |
| Your own screen | Your stored setting (or your browser, if there is none) |
| The screen of someone you share with | **Their browser** |

Even with Japanese set, someone whose browser is English sees English. This is
so that nobody is handed a screen in a language they cannot read.

### It works the opposite way round from the time zone

| | Whose it is |
| --- | --- |
| Language | **The reader's** |
| Time zone | **The owner's** |

Language should follow whoever is reading; a time zone decides what an event
means. [Time zones](/en/docs/time-zones) goes into this.

## Language does not change what is shared

Settings says so too.

> The language setting does not affect how shared open time is calculated.

Changing the language does not change the time ranges the other person sees.
Only the words on screen change.

## A moment of the browser's language after signing in

Just after signing in, for the brief moment before the stored setting has
loaded, the screen may be in your browser's language. It switches to the
stored one once loading finishes.

Using a stored language before the setting has loaded could leave another
account's setting on screen, so it is not used until it can be read.

## When saving fails

If a save fails, **the display language does not change.**

| | What happens |
| --- | --- |
| The screen's language | Stays as the stored one |
| What you selected | Stays in the control |
| The error | The reason is shown |

If an unsaved change moved the screen's language, there would be no telling
whether the save had worked. The screen's language follows **only a value that
saved successfully**.

Press **Save** again to retry.

## The language of this guide

This guide can be read in Japanese and English. **The guide's language is
separate from the interface's, and is decided by the URL:** `/ja/docs/...` is
Japanese and `/en/docs/...` is English. That way a guide link you were sent
reads as the sender saw it.

Opening a chapter in English that has not been translated shows the Japanese
text, with a notice saying so. Showing a readable language is more use than
leaving an untranslated chapter blank.

## What to read next

| Chapter | About |
| --- | --- |
| [Time zones](/en/docs/time-zones) | The asymmetry language is paired with |
| [What people you share with see](/en/docs/what-viewers-see) | What appears on their screen |
| [FAQ](/en/docs/faq) | Questions about the language setting |
