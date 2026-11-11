# Stage 5: dating of the noAI group (declared no AI), cohort 1.22 (extract-2026-11-02-all)

Aggregates only. The per-mod table (mod ids, snapshot timestamps, quoted statements) of the original working note is not published.

Run 2026-11-02..10 with `scripts\Find-WaybackDeclarations.ps1 -Population noai` (the default `ai` is the stage 4b run). Same definitions as stage 4b:
cut = max(2026-04-21, creation + 14 days); early = statement present on the last Wayback snapshot before the cut; late = absent there (and that
snapshot is at least 14 days after creation); undetermined = only snapshots inside the 14-day grace, or none. The ModDB tag does not count.
Changelog statements are dated by the first release carrying them. Sequential requests, 3 s pauses, retry on 503, sleep block
via SetThreadExecutionState (logged "ok" in every run).

Population: cohort 1.22, downloads >= 50, has a NOT_USED label and no USED label = 16 mods. 15 have the label from the description text (run in 4 stages:
2 / 3 / 3 / 7 mods); 1 from a changelog. Two manual decisions: one mod whose script verdict was "keyword match, quote not exact" was checked by hand
on the archived page and set to early (the quote marks inside the statement broke the exact match); the changelog-labelled mod is dropped from noAI
because its label is a changelog line that is not a no-AI statement (it counts as "rest"). FINAL noAI group: 15 mods.

Outcome of the script on the 15 description-labelled mods: 6 early by the script, 1 early by hand check, 5 late, 3 undetermined.
Of the late ones, one needed a closer look: the statement was absent from the newest snapshot as well, so it was added very recently; it is late.
The three undetermined mods have only grace-period snapshots before the cut (statement absent there, present on later ones).

## Final numbers (updated = release for the next game version within 195 days; from results\stage4b-cohort-extract-2026-11-02-all.md)

| noAI group | n | updated | share | 95% CI (Wilson) | author-weighted | authors |
|---|---|---|---|---|---|---|
| early | 7 | 5 | 71% | 36-92% | 67% | 6 |
| late | 5 | 5 | 100% | 57-100% | 100% | 5 |
| undetermined | 3 | 2 | 67% | 21-94% | 67% | 3 |
| all noAI | 15 | 12 | 80% | 55-93% | 81% | 13 |

Before (undated, 16 mods including the dropped changelog-labelled one): 13 updated (81%). For comparison: AI-early 25/45 = 56%; rest + AI-late 1681/3221 = 52%.
The pre-registered view gains one row, noAI-early 5/7 (71%, wide CI), which does not clearly separate from AI-early (56%) or the baseline (52%).

Changes in the stage 4b report caused by this step: only the noAI rows and the rest group changed (rest 3175 -> 3176 mods, 1637 -> 1638 updated, because the dropped mod moved there and was updated; rest + AI-late 3220/1680 -> 3221/1681, both 52%). AI-early (45, 25), AI-late (45, 43), all (3289, 1720) are unchanged.

## Notes

- Only 7 of 15 (47%) noAI statements are dated early; 5 are late and 3 undetermined, so the statement is often added after the update window began, as with AI statements.
- All 5 late noAI mods were updated, so the high noAI share (80%) is not an "early declarer" effect.
