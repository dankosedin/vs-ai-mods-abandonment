# Results: which file backs which part of the post

All files are aggregates (no author names, no mod names or ids) of the snapshot of 2026-11-02. They were produced by the scripts in `..\scripts\`
from the private extract `extract-2026-11-02-all` (see `..\README.md`); the table below names the script per file. `..\claims-register.md` links every number of the post to a file and a script.
`..\scripts\Test-Reproduce.ps1` re-runs the scripts and checks the key numbers.

Several files were edited after generation, in text only (numbers unchanged; `author-bootstrap`, `growth-by-release`, `ai-cohorts-labels` and `ai-labels` had a private mod id, a first-person phrase or a private file path reworded): the Ukrainian headers of `release-download-share.md` and
`youtube-rate.md` were translated and decimal commas / thousands separators written with the locale of the author's machine were
turned into points / commas; the notes of `stage4b-code-content-...md` and `hidden-ai-estimate-...md` that compared the output with an
earlier private working note were removed (the obsolete "15 popular mods" section of the second file too). Two files are
summaries of private per-mod working notes: `stage5-noai-dating-...md` and `stage4b-review-summary.md`.
Result files of partial samples used during development (the 3,084 / 4,190 / 5,200 / 7,250-mod samples, staged code / content
and repository runs) are not included.

| post section | file | script |
|---|---|---|
| Data: 9,291 mods, 50k+ releases, 3,411 authors | `cohorts-...-all.md` (header), `author-retention-...-all.md` | `Get-Cohorts.ps1`, `Get-AuthorRetention.ps1` |
| 1. Are there really more mods? (1,323 at 1.19, 9,291 now, x7, +100% per year) | `growth-by-release-...-all.md` | `Get-GrowthByRelease.ps1` |
| 2. Are mods dropped more often? (cohort table, 195 days, margin of error) | `cohorts-...-all.md` | `Get-Cohorts.ps1` |
| 3. The fate of a mod is decided early (30 / 90 / 195 days, releases already survived) | `cohorts-...-all.md` | `Get-Cohorts.ps1` |
| 4. The author, not the tool (tenure rows; code vs content by game version) | `cohorts-...-all.md`, `code-content-...-all.md` | `Get-Cohorts.ps1`, `Get-CodeContent.ps1` |
| 5. Audience proxies (34 popular mods, Twitch hours by quarter) | `release-download-share.md`, `youtube-rate.md` (+ `youtube-rate.csv`, YouTube monthly rates only) | `Get-ReleaseDownloadShare.ps1`, `Get-YouTubeRate.ps1` |
| 6. Mods vs authors per quarter, x3.4 / x3.2, mods per author, share from productivity | `quarterly-authors-...-all.md`, `mods-vs-authors-...-all.md` | `Get-QuarterlyAuthors.ps1`, `Get-ModsVsAuthors.ps1` |
| 6. How many AI mods (549, 5.9%, 262 of 3,411, share of new mods by quarter) | `ai-labels-...-all.md`, `quarterly-authors-...-all.md` | `Merge-AiLabels.ps1`, `Find-AiDeclarations.ps1`, `Get-QuarterlyAuthors.ps1` |
| 6. Repositories, traces, detection rate, 42-43% estimate | `repo-ai-...-all.md`, `hidden-ai-estimate-...-all.md` | `Get-RepoAiSummary.ps1`, `Get-HiddenAiEstimate.ps1` |
| 7. AI mods, first glance: 71% (70/98) vs 52% | `ai-cohorts-labels-...-all.md` (labels), `stage4b-cohort-...-all.md` | `Compare-AiCohorts.ps1`, `Get-Stage4bCohort.ps1` |
| 7. Dated declarations: 56% (25/45) early, 96% (43/45) late, 8 undetermined | `stage4b-cohort-...-all.md`, `stage4b-review-summary.md` | `Get-Stage4bCohort.ps1`, `Find-WaybackDeclarations.ps1` |
| 7. "No AI" declarations: 80% (12/15), 71% (5/7) early | `stage4b-cohort-...-all.md`, `stage5-noai-dating-...-all.md` | `Get-Stage4bCohort.ps1`, `Find-WaybackDeclarations.ps1 -Population noai` |
| 7. Hidden AI updated 75% vs 63% | `repo-ai-...-all.md` | `Get-RepoAiSummary.ps1` |
| 7. Returning authors (roughly 4 in 10 against 3 in 10) | `author-retention-...-all.md`, `returning-authors-...-all.md` | `Get-AuthorRetention.ps1`, `Get-ReturningAuthors.ps1` |
| Objections: hidden AI would have to be 6% / 13% / 28% / 48% | `hidden-ai-estimate-...-all.md` | `Get-HiddenAiEstimate.ps1` |
| Objections: author-weighted 46% vs 52%; bootstrap +3 points (-12 to +19), +20 for all declarers | `author-weighted-...-all.md`, `author-bootstrap-...-all.md` | `Get-AuthorWeighted.ps1`, `Get-AuthorBootstrap.ps1` |
| Objections: AI code 70% vs 61%, AI content 18% vs 44% | `stage4b-code-content-...-all.md`, `author-bootstrap-...-all.md` | `Get-Stage4bCodeContent.ps1`, `Get-AuthorBootstrap.ps1` |
| Objections: new mods 56% / 63% at 30 / 90 days vs 47% / 51% | `new-mods-...-all.md`, `new-mods-...-all-cut.md` | `Get-NewMods.ps1` |
| Limits: "about 10 wrong mods out of 45", sensitivity 53% | `..\METHODOLOGY.md` (section 6 and 3) | arithmetic, no script |
| Method of dating (manual cases) | `stage4b-review-summary.md` | `Find-WaybackDeclarations.ps1` |

`-...-` stands for `extract-2026-11-02-all`.
