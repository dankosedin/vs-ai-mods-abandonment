# Returning authors on dated labels (extract-2026-11-02-all)

Definitions as in Get-AuthorRetention.ps1: author = ModDB author field; first mod = earliest created; new mod = another mod created 7..W days after the first; active = any release 30..W days after the first; only authors whose first mod is at least W days before 2026-11-02; Wilson 95% intervals. Unit = author (n = authors). The post's 41% / 29% come from results\author-retention-extract-2026-11-02-all.md (2026H1, W = 90, row 'new mod'), produced by scripts\Get-AuthorRetention.ps1 (claims-register row 48).

## 2026H1, W = 90 (eligible authors 886)

### Old labels (first mod has a current USED label)

| group | authors | new mod | active |
|---|---|---|---|
| AI (current labels) | 54 | 41% [29-54] (22/54) | 48% [35-61] (26/54) |
| rest | 832 | 29% [26-32] (242/832) | 34% [31-37] (282/832) |

Reproduction check against the post / author-retention report (22/54 vs 242/832 new mod; 26/54 vs 282/832 active): REPRODUCED.

### New labels (group of the first mod, stage 4b / 5)

| group of the first mod | authors | new mod | active |
|---|---|---|---|
| AI-early | 13 | 38% [18-64] (5/13) | 54% [29-77] (7/13) |
| AI-late | 2 | 100% [34-100] (2/2) | 100% [34-100] (2/2) |
| AI-undetermined | 4 | 25% [5-70] (1/4) | 25% [5-70] (1/4) |
| noAI-early | 3 | 33% [6-79] (1/3) | 100% [44-100] (3/3) |
| noAI-late | 2 | 50% [9-91] (1/2) | 100% [34-100] (2/2) |
| noAI-undetermined | 1 | 0% [0-79] (0/1) | 100% [21-100] (1/1) |
| rest | 376 | 26% [22-31] (98/376) | 34% [29-38] (126/376) |
| outside dated set, current AI label | 35 | 40% [26-56] (14/35) | 46% [30-62] (16/35) |
| outside dated set, other | 450 | 32% [27-36] (142/450) | 33% [29-38] (150/450) |
| noAI, all dated | 6 | 33% [10-70] (2/6) | 100% [61-100] (6/6) |
| AI-early | 13 | 38% [18-64] (5/13) | 54% [29-77] (7/13) |
| everything else (pooled) | 873 | 30% [27-33] (259/873) | 34% [31-38] (301/873) |

## 2025H2, W = 180 (eligible authors 647)

### Old labels (first mod has a current USED label)

| group | authors | new mod | active |
|---|---|---|---|
| AI (current labels) | 12 | 58% [32-81] (7/12) | 67% [39-86] (8/12) |
| rest | 635 | 30% [27-34] (192/635) | 42% [38-46] (265/635) |

### New labels (group of the first mod, stage 4b / 5)

| group of the first mod | authors | new mod | active |
|---|---|---|---|
| AI-early | 8 | 63% [31-86] (5/8) | 75% [41-93] (6/8) |
| AI-late | 2 | 100% [34-100] (2/2) | 100% [34-100] (2/2) |
| AI-undetermined | 0 | - | - |
| noAI-early | 2 | 50% [9-91] (1/2) | 50% [9-91] (1/2) |
| noAI-late | 1 | 100% [21-100] (1/1) | 100% [21-100] (1/1) |
| noAI-undetermined | 0 | - | - |
| rest | 527 | 31% [28-36] (166/527) | 44% [40-48] (232/527) |
| outside dated set, current AI label | 2 | 0% [0-66] (0/2) | 0% [0-66] (0/2) |
| outside dated set, other | 105 | 23% [16-32] (24/105) | 30% [22-39] (31/105) |
| noAI, all dated | 3 | 67% [21-94] (2/3) | 67% [21-94] (2/3) |
| AI-early | 8 | 63% [31-86] (5/8) | 75% [41-93] (6/8) |
| everything else (pooled) | 639 | 30% [27-34] (194/639) | 42% [38-46] (267/639) |

Note: the dated groups exist only for first mods in the dated population (cohort 1.22, downloads >= 50); a first mod made in 2026H1 with fewer downloads or no 1.22 release is in an "outside dated set" row. The latter AI row uses current (undated) labels.
