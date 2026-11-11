# Stage 4b: AI declarations dated against the reference point, cohort 1.22 (extract-2026-11-02-all)

Cohort 1.22, downloads >= 50, n = 3289. Updated = a release for the next game version within 195 days. Reference point 2026-04-21 (stable 1.22).

**Coverage:** 98 mods declare AI (stage 4 labels). Dated 98 (early 45, late 45, undetermined 8); needs review 0; pending (no stage 4b result yet) 0. All AI mods are dated.

Dating: a changelog declaration is dated by the creation of the first release that carries it. A description declaration is early if it was on the last Wayback Machine snapshot before the cut (cut = max(reference point, mod creation + 14 days)), late if absent there, undetermined if the only snapshots before the cut fall in the first 14 days or none exist; verdicts of the search script are checked by hand. A mod declared in both is early if either is early. The ModDB "AI" tag is not counted as a declaration.

| group | n | updated | share | 95% CI (Wilson) | author-weighted | authors |
|---|---|---|---|---|---|---|
| AI, declared before the reference point (AI-early) | 45 | 25 | 56% | 41-69% | 59% | 36 |
| AI, declared after (AI-late) | 45 | 43 | 96% | 85-99% | 89% | 18 |
| AI, undetermined | 8 | 2 | 25% | 7-59% | 40% | 5 |
| AI, needs review | 0 | - | - | - | - | 0 |
| AI, pending | 0 | - | - | - | - | 0 |
| AI, all (current labels, undated) | 98 | 70 | 71% | 62-79% | 67% | 53 |
| declared no AI (noAI), all | 15 | 12 | 80% | 55-93% | 81% | 13 |
|   noAI, declared before the reference point (noAI-early) | 7 | 5 | 71% | 36-92% | 67% | 6 |
|   noAI, declared after (noAI-late) | 5 | 5 | 100% | 57-100% | 100% | 5 |
|   noAI, undetermined | 3 | 2 | 67% | 21-94% | 67% | 3 |
|   noAI, needs review / pending | 0 | - | - | - | - | 0 |
| no declaration (rest) | 3176 | 1638 | 52% | 50-53% | 46% | 1385 |
| all | 3289 | 1720 | 52% | 51-54% | 46% | 1424 |

Pre-registered view (only declarations dated before the reference point count; late declarers fall into "no declaration"):

| group | n | updated | share | 95% CI (Wilson) | author-weighted | authors |
|---|---|---|---|---|---|---|
| declared AI at the reference point (AI-early) | 45 | 25 | 56% | 41-69% | 59% | 36 |
| declared no AI at the reference point (noAI-early) | 7 | 5 | 71% | 36-92% | 67% | 6 |
| no declaration at the reference point (rest + AI-late) | 3221 | 1681 | 52% | 50-54% | 46% | 1391 |

noAI is dated like AI descriptions (Wayback, manual verdicts; stage 5). noAI-late and noAI-undetermined mods are shown in the table above but are not added to the last row, which keeps its AI-stage-4b definition (rest + AI-late); undetermined, needs-review and pending mods are left out of the pre-registered view. Mods listed in stage4b\noai-exclude.csv (labelled NOT_USED but not a no-AI statement) count as rest.

By source of the declaration (mods, updated):

| source | early | late | undetermined | needs review | pending |
|---|---|---|---|---|---|
| description | 37 (20) | 43 (41) | 8 (2) | 0 (0) | 0 (0) |
| changelog | 6 (3) | 2 (2) | 0 (0) | 0 (0) | 0 (0) |
| both | 2 (2) | 0 (0) | 0 (0) | 0 (0) | 0 (0) |

Clustering: mods per author inside the group (largest authors, counts only).

- AI-early: 45 mods, 36 authors; largest: 3, 3, 3, 3, 2
- AI-late: 45 mods, 18 authors; largest: 11, 8, 7, 3, 3

Wayback files read: wayback-s0-n10.csv, wayback-s10-n18.csv, wayback-s28-n18.csv, wayback-s30-n16.csv, wayback-s31-n59.csv, wayback-noai-s0-n2.csv, wayback-noai-s2-n3.csv, wayback-noai-s5-n3.csv, wayback-noai-s8-n7.csv; manual verdicts: 33.
