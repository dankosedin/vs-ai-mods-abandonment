# Stage 4b: manual review of the dating (summary)

Aggregates only. The working note behind this file lists, per mod, the Wayback snapshot timestamps and quoted declarations. It is not published: it names specific mods and quotes their authors' texts.

After the first automatic pass of `scripts\Find-WaybackDeclarations.ps1` over the 98 mods that declare AI in cohort 1.22, 12 mods had no usable dated description declaration (the script found keywords but not the exact labelled quote, or no usable snapshot before the cut). Each was checked by hand against the Wayback CDX list and the archived pages, using the same rule as the script: cut = max(2026-04-21, creation + 14 days); the ModDB "AI" tag is ignored.

| outcome of the hand review | mods | reason |
|---|---|---|
| early | 3 | The declaration is on the last snapshot before the cut, only worded slightly differently from the labelled quote (for one of them the only pre-cut snapshot falls inside the 14-day grace, but the declaration is visible on it). |
| late | 1 | The declaration is absent from every snapshot up to 2026-09-22 (the newest one that exists), so it was added after the cut. |
| undetermined | 8 | No snapshot between the end of the 14-day grace and the cut (the first snapshot after the cut is 1 to 10 days later, or only creation-day snapshots exist). Circumstantial evidence ("last modified" stamps, sibling mods by the same author) leans early for some, but it is not a dating, so they stay out of both groups. |

Two further mods that had been checked in an earlier pilot were re-fetched: their archived pages before the cut contain no AI declaration, so both are late (confirmed).

Resulting groups (see results\stage4b-cohort-extract-2026-11-02-all.md): AI-early 45 mods, AI-late 45, undetermined 8.

Sensitivity used in the post and in METHODOLOGY.md: if 4 of the 8 undetermined mods that most likely declared early were counted as early, the AI-early share would be about 53% (26/49) instead of 56% (25/45). The post does not use this figure.
