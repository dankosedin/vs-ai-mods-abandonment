# Methodology

Question: are mods that declare AI use abandoned more often than other mods on the Vintage Story mod database (ModDB)?
Data: the public ModDB API, one snapshot of **2026-11-02** (the list had 9,292 entries; 9,291 mods were extracted, one was gone
by the time of the fetch), with 50,767 releases and 3,411 distinct author values. Only aggregates are published. The scripts in
`scripts\` hold the exact definitions in their headers; this file summarises them.

"Stage" numbers in the scripts are the order the work was done in: stage 2 code / content, stage 3 repository traces, stage 4
declarations and labels, stage 4b dating of declarations, stage 5 checks of the labels and dating of "no AI" declarations.

## 1. Definitions

- **Mod**: one row of the mod list (all types in growth and author counts; `type = mod` in the cohorts). Deleted mods are not in the
  data. **Author**: the ModDB `author` field of the mod (one per mod). A renamed author appears as two, namesakes merge.
- **Game branch** of a tag: its first two components (`1.21.3-rc.2` -> `1.21`). Stable release dates are in
  `data\derived\game-releases.csv` (1.22 stable: 2026-04-21).
- **Wide mod**: some single release is tagged for 5 or more branches ("compatible with everything"); excluded from all cohorts.
- **Cohort of game release X** (branch B, previous branch P): type `mod`, downloads >= 50, created before the stable release of X,
  has a release tagged P, not wide. The cohort sizes for 1.15 ... 1.22 are 176, 217, 383, 421, 791, 1,113, 1,996, 3,289.
  The 50-download threshold keeps experiments nobody installed out of the numbers.
- **Updated**: the mod has a release tagged B, and the earliest such release was created within **195 days** of the stable release of X
  (a release created before the stable release counts as day 0). The horizon of 195 days is the time from the latest analysed
  stable release (1.22, 2026-04-21) to the snapshot date, so every mod in every cohort is followed for the same time and no
  censoring model is needed. "Updated" is not "alive": many content mods keep working without an update.
- **Backfilled**: the earliest B release was created before pre-release 1 of X, i.e. a B tag added to an old file. They are
  counted in the main tables; a variant without them is in `results\cohorts-...md`.
- **New mods** (measure b): a mod's first publication is its earliest release. It is *updated within H days* if a later release was
  created at least 24 hours after the first and at most H days after it (H = 30, 60, 90, 120, 180). Only mods first published at
  least H days before the snapshot count for horizon H. No downloads threshold (downloads grow with age and a threshold would
  drop the youngest mods). A variant cuts the follow-up at the next stable game release (`-cut` file).
- **Mods that existed at release X**: created on or before the stable release day (the rule gives 1,323 at 1.19; counting only mods
  created before 00:00 of that day gives 1,321, the two mods being created on the release day itself).
- **Active author** in a quarter: a distinct author with at least one mod *created* in that quarter. **New author**: the quarter of
  the author's first mod. Quarterly decomposition of growth: ln(mods ratio) = ln(authors ratio) + ln(mods per author ratio).
- **Code mod**: the release zip has an entry ending in `.dll` or `.cs` (or the release file itself is `.dll`/`.cs`); **content mod**:
  a zip listing without such entries. The release is the mod's latest release before the stable release for cohort rows, and its
  first release for new mods. Listings are read from the zip's central directory only (HTTP `Range` on the end of the file).
- **Audience proxies** (nobody outside the studio knows the number of players): downloads of 34 popular mods that have a release
  for every branch 1.16-1.22 (branch of a release = highest game tag), YouTube videos per day with the game name in the title
  (YouTube Data API search, monthly), and quarterly means of Twitch hours streamed (monthly values read by hand from one public
  statistics page; only the quarterly means are published).

## 2. Labels: who declares AI

Stage 4 turns text into a label per mod in three steps.

1. **Keyword search** (`Find-AiDeclarations.ps1`) over summaries, descriptions and every changelog: tool names and vendors,
   phrases like "made with AI", and the bare word "AI" (which mostly means mob behaviour, so it is only a hint). 1,282 fragments
   in 860 mods.
2. **Model labels**: every fragment gets one label from `USED`, `NOT_USED`, `OTHER_MOD`, `FEATURE`, `MOB`, `OTHER`, `UNCLEAR` with a
   scope (code, art, text, ...), a confidence and the deciding words. Labeller: Claude Haiku, with the prompt in
   `scripts\stage4-label-prompt.md`, kept verbatim. A mod **declares AI** if at least one fragment is `USED`; it **declares no AI**
   if it has `NOT_USED` and no `USED`. 549 mods declare AI (5.9% of all mods, 262 of 3,411 authors).
3. **Check**: a blind, stratified sample of 50 labels (strata: `USED` on bare hits only, `USED` with low confidence, `USED` with high
   confidence, `OTHER`/`UNCLEAR` on tool hits, `NOT_USED`, `MOB`) was labelled again by Claude Sonnet with the same prompt:
   **45 of 50 agree**. The sample is a check of the labeller, not a measurement of the error rate of the final labels.

**Manual overrides.** After the check, a fixed phrase that the labeller got wrong on a recurring boilerplate sentence could be
overridden. The policy: an override is a regular expression over the fragment text, never a mod or author name, and it is made only
after a sample check shows the model mislabelled that sentence consistently. In the published run it touched 30 hits. The
overrides file is private (its reasons name specific mods and authors); `Merge-AiLabels.ps1` works without it, but then the
counts differ slightly from the published ones.

"Declares" means what the page says, not what happened: undeclared mods include hidden AI use, and results are worded as
"declared AI / declared no AI / no declaration".

## 3. Dating the declarations

A declaration written after the update window began is itself a sign of activity and inflates "updated". So each declaration is dated
(stage 4b), against the **reference point = the stable release of 1.22 (2026-04-21)**.

- **Description or summary declarations** are dated with the Internet Archive's Wayback Machine. For each mod the script lists the
  snapshots of the mod page, takes the latest snapshot before the **cut = max(2026-04-21, creation + 14 days)**, fetches the raw
  archived page and checks whether the labelled declaration (the quote, or its matched keywords) is on it.
  - **early**: the declaration is on that snapshot. (The 14-day grace is for authors who fill in the description right after
    creating the mod, which is not a reaction to the update.)
  - **late**: it is not there, and that snapshot is at least 14 days after creation.
  - **undetermined**: not found, but every snapshot before the cut lies inside the 14-day grace, or none exists.
  - The ModDB "AI" tag does not count as a declaration.
  - For non-early mods the newest snapshot is also checked, so a "late" verdict is not a page-format problem (the declaration must
    be visible on archived pages at all).
- **Changelog declarations** are dated by the creation date of the first release that carries them: before the reference point =
  early, otherwise late. A mod declared in both places is early if either source is early.
- **Hand check.** Cases the script cannot decide (keywords found but not the exact quote; no usable snapshot) were checked by hand
  against the CDX list and the archived pages with the same rule. Result for the 12 mods checked after the first pass: 3 early,
  1 late, 8 undetermined (`results\stage4b-review-summary.md`); two earlier pilot cases were re-fetched and confirmed late.
- **Result for cohort 1.22** (98 mods declare AI): **45 early, 45 late, 8 undetermined** (`results\stage4b-cohort-...md`).

**Sensitivity of the dating.** Wayback snapshots are sparse, so some "early" verdicts may be wrong, and the 8 undetermined mods are
left out of both groups. If 4 of the 8 undetermined mods that most likely declared early were counted as early, the AI-early share
would be about **53% (26/49)** instead of **56% (25/45)**. The post does not use this variant.

## 4. Groups and the pre-registered view

In cohort 1.22 (3,289 mods): **AI-early** (45 mods, 36 authors), **AI-late** (45 mods, 18 authors), **AI-undetermined** (8),
**noAI** (15 mods, split early 7 / late 5 / undetermined 3 by the same dating), **rest** (no declaration, 3,176).

**The pre-registered view**: only declarations dated before the reference point count, so late declarers fall into the "no
declaration at the reference point" group: AI-early against **rest + AI-late** (3,221 mods, 52.2% updated), the comparison
the post reports (56%, 25 of 45, against 52%). Undetermined mods are left out of that view. The same rule is used in the
draft pre-registration for 1.23 (`PREREGISTRATION.md`).

**The noAI group (15 mods).** Mods with a `NOT_USED` label and no `USED` label were dated the same way (stage 5). One mod was
dropped from the group because its only `NOT_USED` label came from a changelog line that is not a no-AI statement (a remark about
making some art by hand); it counts as "rest". That leaves 15 mods: 80% (12/15) updated; only 7 of them are dated early (71%, 5 of 7),
all 5 late ones were updated. Before the dating and the exclusion the figure was 81% (13 of 16). The exclusion list is private.

## 5. Estimators and uncertainty

- **Share and Wilson 95% interval** on mods. The Wilson interval ignores clustering by author, so it is too narrow for large
  groups (design effect about 3-4 in the large comparison groups, 1.0-1.6 in the small AI groups).
- **Author-weighted share**: every author has weight 1, split evenly over their mods in the cohort (mean of per-author shares).
  For 1.22: 46% instead of 52% by mods.
- **Cluster bootstrap over authors** (`Get-AuthorBootstrap.ps1`) for the comparisons of the post. For a comparison of group A with
  group B the population is the mods of A and B; authors of that population are resampled with replacement (as many as there are
  authors), each resampled author brings all their mods of the population (authors with mods in both groups bring both), and the
  shares and their difference are recomputed. **10,000 resamples, fixed seed 20261110**, percentile interval 2.5 / 97.5, plus the
  share of resamples with a positive difference. Resamples in which a group is empty are skipped for that group (4 of 10,000 for
  the AI-early content group, 19 for noAI-early). The loop is compiled C# (`Add-Type`) because PowerShell 5.1 is too slow.
  Results: AI-early minus rest + AI-late **+3.4 points (interval -11.6 to +19.4; share of resamples above zero 67.6%)**; all
  declarers minus all non-declared **+19.7 (3.6 to 32.8; counts late declarations)**; code mods +8.2 (-8.8 to +24.0); content mods
  -26.3 (-46.2 to +9.9, only 11 mods from 8 authors).
- **Returning authors** (`Get-AuthorRetention.ps1`, `Get-ReturningAuthors.ps1`): an author's first mod, half-year cohorts; "new mod" =
  another mod created 7 to W days after the first, "active" = any release 30 to W days after the first; only authors whose first
  mod is at least W days before the snapshot. 2026H1, W = 90, current (undated) labels: 41% (22 of 54) of AI authors against
  29% (242 of 832); on dated labels only 19 of the 54 can be dated (AI-early 5 of 13, 38%, against 30% for everyone else).

## 6. Hidden AI

- **Repository traces** (stage 3): for mods with a public repository (2,160 mods, 23%), commit metadata only: AI agent files and
  folders, AI co-author trailers, "generated with" lines, agent accounts, agent branch names; dated by the earliest such commit.
  Detection rate of the traces: they find 80 of the 178 declaring mods that have a repository, **45%**.
  Traces dated before the reference point only count for the update comparison (traces dated later imply commits after it).
- **Corrected share** = observed share / 0.45. For mods created in 2026 with a repository: 19% show traces (169 of 871),
  corrected about 42-43% (variants 41.8-43.2%), against 17.8% (155 of 871) who declare. It is an estimate on a biased group
  (authors with repositories are more engaged) and says nothing about mods without a repository.
- **Hidden AI among non-declared repository mods** of cohort 1.22: 2.0% (16 of 809) with a trace dated before the release; among
  new mods of the 1.22 window 12.7% (61 of 482), about 28% corrected.
- **Tipping point.** Let p be the share updated among declared AI mods, r the share updated among the "rest", and suppose the rest
  contains a share h of hidden AI mods that are updated with rate a, while the other rest mods are updated like the declared group:
  `r = h*a + (1-h)*p`, so **`h = (p - r) / (p - a)`**. For AI-early (p = 55.6%) against rest + AI-late (r = 52.2%): h = 6.1% if
  a = 0 (hidden AI is never updated), 13.2% if a = 0.30. For all declarers (p = 71.4%) against the undeclared rest (r = 51.6%):
  h = 27.8% (a = 0) and 48.0% (a = 0.30). The table is in `results\hidden-ai-estimate-...md` (with a = 0.50 as well).
- **Arithmetic behind "about 10 wrong mods out of 45".** If x of the 45 AI-early mods were really late declarers (updated at 96%,
  so almost always updated), the early share becomes (25 - x) / (45 - x): x = 9 gives 16/36 = 44.4%, x = 10 gives 15/35 = 42.9%;
  solving for 44% gives x of about 9.3. So 9 to 10 wrong mods would move 56% down to 44%. If the wrong mods were instead not updated,
  many more would be needed; mislabelled "late" mods that were really early would raise the share.

## 7. Limits

- The conclusion about AI rests on **one game release (1.22) and 45 mods from 36 authors**; most AI mods appeared after 1.22 and
  have not faced a game release yet (by current declarations AI is 8%, 12% and 24% of new mods in 2026Q2, Q3, Q4). The check on
  1.23 is pre-registered (`PREREGISTRATION.md`).
- "Updated" is not "alive"; content mods often work without updates; the code / content split is a partial answer.
- Authors who write any declaration are not typical authors ("no AI" declarers update 80%); the tool cannot be separated from the
  person who uses it. Mods of one author are not independent.
- Labels use current texts, so the shares of AI among new mods and the author-return figures lean upward (late declarations
  included). Only mods that still exist are in the data (deleted mods cannot be counted).
- Wayback snapshots are sparse; dating can be wrong in either direction (section 3).
- The audience proxies measure downloads (player x server x version) and streamed hours, not players.
- Conflict of interest: the author is a mod author and uses AI assistants, including for this analysis.
- Quality is a matter of taste and is not measured.

## 8. Known discrepancies

None of these changes a number of the post at its stated precision.

- The share of "other" code mods is 61.47% (892 of 1,451) in `stage4b-code-content-...md` and 61.50% (893 of 1,452) in
  `author-bootstrap-...md`: one code mod that was labelled noAI in the first and counted as rest in the second (the exclusion of
  section 4). The post says 61%. `Test-Reproduce.ps1` expects the bootstrap value.
- The tipping-point thresholds (6%, 13%, 28%, 48%) were computed on a baseline one mod older (1,680 of 3,220 instead of 1,681 of
  3,221); the difference is below 0.1 point.
- 1,323 mods at 1.19 uses the day-inclusive rule (created on or before the release day); the strict rule gives 1,321.
- The share of AI among new mods per quarter and the 41% / 29% returning-author figures use current labels (not dated).
- "Margin of error of about 2 points" for the cohort shares is a normal-approximation interval on mods without clustering by author.
- 2026Q4 is partial (to the snapshot date) and is not used for ratios.
