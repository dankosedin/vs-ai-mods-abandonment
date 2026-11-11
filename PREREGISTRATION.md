# Pre-registration: are mods made with AI abandoned more often? (game release 1.23)

**Status: DRAFT. Not fixed until it is published with a dated commit before the stable release of 1.23. Anything marked
"OPEN" is a decision the author still has to make; the draft proposes a default.**

## Why pre-register

Most mods that declare AI use were first published in 2026, after the stable release of 1.22 (2026-04-21). They have
not yet met a game release, so the main question (is a mod updated for the next game version?) cannot be answered for
them yet. The 2026-11-02 study (`METHODOLOGY.md`) covers the 45 mods that declared AI before the release of 1.22. This document
fixes the method for 1.23 before the data exists: the analysis then runs as written, and every planned result is reported
whatever it shows. Deviations, if any, are listed separately with reasons.

Conflict of interest: the author makes mods with AI assistance.

## Definitions carried over from the 2026-11-02 study

These are the definitions of the scripts in `scripts\` (see `METHODOLOGY.md`); the analysis reuses the same code.

- **Cohort of game release X**: mods of type `mod`, created before the stable release of X, with a release tagged for the previous
  branch, not "wide" (no single release tagged for 5 or more game branches), with at least **50 downloads** at the time the
  groups are fixed.
- **Updated**: a release tagged for X, created no later than **195 days** after the stable release of X (a release created before
  the stable release counts as day 0). 30 and 90 days are reported alongside. 195 days is the follow-up that the 1.22 cohort has
  by 2026-11-02, so the horizon is the same as in the earlier cohorts.
- **Declared AI, declared no AI, no declaration** (labels): a keyword search over summary, description and changelogs, then a model
  label per fragment with the prompt in `scripts\stage4-label-prompt.md`. A mod declares AI if at least one fragment is labelled
  USED; declares no AI if it has NOT_USED and no USED; otherwise it has no declaration.
- **Dating** (AI-early / AI-late / undetermined): a declaration is *early* if it was on the mod page before the reference point,
  *late* if it appeared after, *undetermined* if the archive cannot tell (rules and the 14-day grace in `METHODOLOGY.md`).
  For 1.23 the groups are fixed from a snapshot taken on the reference day, so the dating is by construction (see below); the
  Wayback dating is only needed for the existing 2026-11-02 data.
- **Pre-registered view**: only declarations dated before the reference point count. Declared AI before the reference point
  (AI-early) is compared with *no declaration at the reference point* (which includes mods that declared later). Undetermined
  mods are left out of that comparison and reported separately.
- **Uncertainty**: the unit of analysis is the mod, the unit of resampling is the author (mods of one author are not independent).
  Intervals come from a **cluster bootstrap over authors**: authors are resampled with replacement, each brings all their mods
  of the compared groups, **10,000 resamples**, percentile 2.5 / 97.5, **fixed seed** (a new seed is written into the script
  and published with this document; the seed of the 2026-11-02 study was 20261110).
- **Code / content split**: a mod is *code* if its release zip contains a `.dll` or `.cs` entry (or the release file itself is
  `.dll`/`.cs`), *content* otherwise.

## Data

- Source: the public API of the Vintage Story mod database (mods.vintagestory.at): mods, releases, release dates,
  game-version tags, per-release downloads, descriptions and changelogs, fetched with the polite fetch scripts of this repository.
- **Snapshot S0** (exposure): taken on the day of the stable release of 1.23 (date per the official version history).
  The stable release, not pre.1, so that the creation window and the cohort match the earlier cohorts.
  Group labels and the downloads threshold come from S0 only, so neither can depend on the outcome.
- **Snapshot S1** (outcome): taken at least 195 days after the stable release of 1.23.
- The existing snapshot of 2026-11-02 is already labelled; it is used for a sensitivity check of the labels.

## Population

- **Primary:** new mods of window 1.22, i.e. mods whose first release was created on or after 2026-04-21 and before
  the stable release of 1.23, of type "mod", with a release tagged 1.22.x, not "wide". No downloads threshold: downloads grow
  with age, and a threshold would drop the youngest mods. Sensitivity: at least 50 downloads in S0.
- **Secondary:** the full cohort of 1.23: all mods meeting the same criteria, created at any time before the stable
  release of 1.23, with at least 50 downloads in S0 (as in the earlier cohorts); without the threshold as sensitivity.

## Outcome

- Updated: the mod has a release tagged 1.23.x created no later than H days after the stable release of 1.23
  (releases tagged during pre-release / release candidates count as day 0).
- H = 195 days (primary); 30 and 90 days reported alongside.
- Tags added to an old file (the earliest 1.23 release was created before pre.1 of 1.23) are counted in the primary
  analysis and excluded in a sensitivity variant.

## Groups

Labels from the mod's summary, description and changelogs **as of S0**, found by the same keyword search and labelled
by the same model prompt as in the 2026-11-02 study, with the same manual-override policy (a fixed phrase, never a mod or author name):

- **AI**: at least one fragment labelled USED (the author says AI was used to make the mod or part of it);
- **noAI**: at least one NOT_USED and no USED (the author says no AI was used);
- **undeclared**: everything else.

Results are worded as "declared AI use / declared no AI use / no declaration", never as "AI / not AI": undeclared
mods include hidden AI use.

**Only signs dated before the reference point count.** A sign of AI use (a declaration, a trace in a repository) that
first appeared after the reference point (the stable release of 1.23 for the cohort; for new mods, the date the
group is fixed, S0) is itself evidence of activity after it and would inflate "updated" for that group. In the
2026-11-02 study, AI traces in repositories gave 91% updated when all traces counted and 75% when only traces dated
before the reference point counted. Labels therefore come from S0 only, never from S1 or later edits.

**Additional group (not primary): AI by repository traces.** Mods with a linked public repository whose history
before S0 shows AI tooling (agent instruction files, AI co-author lines in commits), found by the same scripts as in
the 2026-11-02 study and dated by the earliest such commit. Reported split into "traces and declaration"
and "traces, no declaration" (hidden AI use), against "repository, no traces". Only about a quarter of mods link a
repository, so this group is a check on hidden AI use among undeclared mods, not a replacement for the declared groups.

## Analysis

**Primary comparison:** share updated within 195 days, declared AI vs no declaration, in the primary population (new mods of
window 1.22), with the difference and its cluster-bootstrap 95% interval.

**Secondary comparisons** (all reported, none replaces the primary):

1. The same comparison in the full 1.23 cohort (>= 50 downloads).
2. Declared AI vs declared no AI (does the difference come from declaring authors rather than from AI?).
3. Shares weighted by author (each author counts once) as a check.
4. Stratified by author experience: the mod is the author's first mod vs the author had earlier mods (S0).
5. Context: the same measure for new mods of earlier windows (1.15 to 1.21), which predate common AI coding tools.
6. Stratified by mod kind (**code** vs **content**), each AI group compared with undeclared mods of the same kind. The release is the
   mod's first release for new mods and its latest release created before the stable release of 1.23 for the cohort, so the kind
   is fixed before the outcome. Reason: a content mod often keeps working on a new game version without an update, so "not
   updated" means less for it, and in the 2026-11-02 data mods that declare AI are more often code mods (cohort 1.22: 66% vs 45%;
   new mods of window 1.22: 77% vs 59%).
7. 30 and 90 days; with and without the downloads threshold; with and without tags added to old files.
8. Hidden AI: the repository-trace group against repositories without traces.

## What would count as support or refutation

- **Support for "mods that declare AI use are abandoned more often"**: the share updated for AI is lower than for undeclared mods,
  with the 95% interval of the difference entirely below zero, in the primary population at H = 195.
- **Support for "not abandoned more often"** (the margin is fixed by the author at 10 percentage
  points, written down here before the data exists): the 95% interval of the difference lies entirely above -10 points.
  If the interval contains both zero and values below -10, the result is reported as **inconclusive**, not as "no difference".
- **Not attributed to AI**: if AI is lower than undeclared mods but not lower than noAI, the difference is attributed to
  declaring authors, not to AI, and reported as such.
- **Code / content disagreement**: if the overall difference and the within-kind differences (analysis 6) disagree, the
  within-kind result is the one reported as the effect, and the overall difference is described as a mix of kinds.
- **Expectation stated in advance** (from the early-activity measure on the 2026-11-02 data): AI about equal to noAI,
  both at or above undeclared mods. The result is reported in full either way, including any group with too few mods
  (fewer than 20 mods in a group: reported, not interpreted).

## Already known when this was written

The 2026-11-02 snapshot and its results (cohorts 1.15 to 1.22, early activity of new mods by window, labels, dating of the
1.22 declarations, the author bootstrap) were computed before this draft. They motivated the design and are published with it.
This includes the code vs content split (analysis 6), added after the 2026-11-02 results by kind were seen: in cohort 1.22, code
mods were updated 62% and content mods 44%; mods that declared AI before the reference point were updated 70% (code, 23 of 33) and
18% (content, 2 of 11). No data on updates for 1.23 existed at the time of writing.

## Open decisions (to settle before publishing)

- Settled: the equivalence margin (10 points) and the minimum group size (20 mods).
- OPEN: the seed of the bootstrap (to be chosen and written here before S0).
- OPEN: the exact date of S0, which is the stable release date of 1.23 once it is announced; this file is published before that date.
