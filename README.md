# ModDBResearch

Scripts, aggregated results and methodology for the study "Deep dive into AI-slop" on the Vintage Story mod database
(mods.vintagestory.at): are mods made with AI abandoned more often than other mods? Data cut-off: **2026-11-02**.

This repository contains how to obtain the data and how to run the calculations. It does not contain the data itself.

## The raw data is not published

The extract (mod names, authors, release dates, descriptions, changelogs, repository links, labels, saved web pages) stays private:

- it contains the names of mod authors, and this study reports aggregates only, never individual authors or individual mods;
- the descriptions, changelogs, archived pages and Twitch statistics belong to their owners and sites, and the sites' terms and
  rules (for example, the statistics site asks not to be scraped) do not allow redistributing them;
- a re-fetch of ModDB gives a different snapshot every day, so a published copy would only freeze one of many possible ones.

What is published: the scripts (`scripts\`), every aggregated result that backs a number of the post (`results\`), aggregated
derived tables (`data\derived\`), the methodology, the claims register and the draft pre-registration for game version 1.23.
You can rebuild the data yourself (below), or, if you have the original extract, reproduce the published numbers exactly
(section "Verify the numbers").

## Contents

```
README.md             this file
METHODOLOGY.md        definitions, cohorts, labels, dating rules, estimators, limits
PREREGISTRATION.md    DRAFT pre-registration of the analysis for game version 1.23
claims-register.md    every number of the post -> results file -> script
scripts\              PowerShell 5.1 scripts (ASCII only); scripts\cache\ fetches data from the network
results\              aggregated outputs, see results\README.md for which file backs which part of the post
data\derived\         aggregated tables only (game-releases.csv)
data\private\         NOT in the repository (git-ignored): the extract and the caches, see below
```

Requirements: Windows PowerShell 5.1, network access for the fetch scripts, `git` for the repository step, optionally the `gh` CLI
(GitHub metadata) and an LLM for the labelling step. No other tools. Run scripts like this:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\<Script>.ps1 [parameters]
```

Every script takes `-DataDir` (default `data\private`): the folder that holds the extract folders and the cache. Results are
written to `results\` of this folder.

## How to obtain the data

Layout of `data\private\` after all steps (the names are what the scripts expect):

```
data\private\
  moddb-cache\                      raw API responses: modlist-<date>.json, mods\<modid>.json, files\<fileid>.json, repos\..., index.csv
  extract-2026-11-02-all\           the extract: mods.csv, releases.csv, meta.txt, cohort-rows.csv, ai-hits.csv, ai-labels.csv,
                                    ai-mods.csv, repo-urls.csv, stage2\, stage3\, stage4\, stage4b\, stage5\
  audience\youtube\                 monthly YouTube search results (raw), audience\twitch\sullygnome-monthly.csv (hand-made)
  label-overrides.csv               optional manual label decisions (private, see METHODOLOGY.md)
```

### Step 0. Fetch ModDB politely (the ModDB API)

`scripts\cache\Update-ModDbCache.ps1` downloads the mod list (`/api/mods`) and every mod (`/api/mod/<id>`) into
`data\private\moddb-cache`. The API has no documented rate limit and no robots.txt, so the script limits itself:

- strictly sequential, one request at a time, at least `-DelayMs` (default 1000) between requests;
- a descriptive User-Agent (`vs-mod-research/1.0 (personal non-commercial research)`), no login, no cookies;
- on 429, 5xx, timeout or connection error it backs off 30 s, 1, 2, 4, 8 minutes (honouring `Retry-After`) and stops after 5
  failures in a row; on 403, a non-JSON body or an unexpected status it stops at once;
- resumable and incremental: files are written atomically, a rerun refetches only mods that changed (the list entry carries the
  last-release date and comment count) or are older than `-MaxAgeDays`; `-Limit` caps one run (about 9,300 mods take roughly
  2.6 hours at 1 s per request, so spread it over several days if you prefer);
- it blocks the machine's idle sleep while running (`SetThreadExecutionState`, system only).

```powershell
scripts\cache\Update-ModDbCache.ps1 -Limit 1000      # repeat until the whole list is cached
```

### Step 1. Freeze an extract

`scripts\Export-Extract.ps1 -ListDate <yyyy-MM-dd>` copies what the study needs from the cache into
`data\private\extract-<date>-<n>\` (`mods.csv`, `releases.csv`, `meta.txt`). The study used the list of 2026-11-02, the whole
list (`-Sample 0`, folder `extract-2026-11-02-all`, 9,291 mods). The published numbers belong to that snapshot. ModDB changes
daily, so a fresh fetch gives slightly different numbers; only the original extract reproduces them exactly.

### Step 2. Cohorts

`scripts\Get-Cohorts.ps1` writes `cohort-rows.csv` (one row per mod and game release) and `results\cohorts-<extract>.md`.

### Step 3. AI labels (stage 4) and their check (stage 5)

1. `Find-AiDeclarations.ps1`: keyword search in summaries, descriptions and changelogs (local, from the cache) -> `ai-hits.csv`.
2. `Split-AiHits.ps1`: cuts the hits into batches. Each batch is labelled by a model with the prompt in
   `scripts\stage4-label-prompt.md` (the study used Claude Haiku, one agent per batch, output `stage4\out-NN.txt`).
3. `Merge-AiLabels.ps1`: joins the labels -> `ai-labels.csv`, `ai-mods.csv`. An optional overrides file is described in METHODOLOGY.md.
4. `Sample-Stage5.ps1`: a stratified blind sample of 50 labels that a stronger model (Claude Sonnet) labels again; 45 of 50 agree.

### Step 4. Repository traces (stage 3)

`Export-RepoUrls.ps1` lists source-repository links; `scripts\cache\Update-RepoCache.ps1` reads commit metadata only
(`git clone --bare --filter=blob:none` into a temporary folder, no checkout, nothing executed, no file contents; sequential,
2 s between repositories, GitHub metadata through the `gh` CLI); `Find-RepoAiTraces.ps1` finds AI tooling traces and dates them.

### Step 5. Code vs content (stage 2)

`Export-ReleaseFiles.ps1` picks the release file per row; `scripts\cache\Update-FileCache.ps1` reads only the end of each release zip
with an HTTP `Range` request (the zip's central directory; no download of whole files; sequential, 1 s between requests, same
back-off rules as above); `Get-CodeContent.ps1` classifies each file as code (`.dll`/`.cs` in the zip) or content.

### Step 6. Dating the declarations (stage 4b and 5)

`Find-WaybackDeclarations.ps1` asks the Internet Archive's Wayback Machine CDX API for snapshots of each declaring mod's page and
checks whether the declaration was already on the last snapshot before the reference point (rules in METHODOLOGY.md). Wayback
politeness: strictly sequential, `-DelayMs` between requests (default 4000 ms; 3 s was used for the second population), back-off on
429/5xx, stop on repeated failures, sleep blocked while running, staged runs with `-Skip`/`-Sample` (10 / 20 / 20 / 50% of the
population, findings checked after each stage). `-Population noai` dates the "no AI" declarations the same way.
The verdicts that the script cannot give (keywords found but not the exact quote, no usable snapshot) are decided by hand and
written to `stage4b\manual.csv` (columns `modid,final,reason`); a label that is not a real no-AI statement goes to
`stage4b\noai-exclude.csv` (columns `modid,reason`). Both files are private (they name mods). `Get-Stage4bCohort.ps1` combines
everything into `stage4b\cohort-dating.csv` and `stage4b\cohort-groups.csv`.

### Step 7. Audience proxies

`Get-YouTubeMonthly.ps1` queries the YouTube Data API v3 (`search.list`, one request per month and page, resumable, stops cleanly on
quota exhaustion; the API key is read from a file you provide with `-KeyFile`, never logged). The monthly Twitch figures of the
post were read by hand from the public Twitch statistics site SullyGnome (sullygnome.com), not scraped; only quarterly means are published
(`results\youtube-rate.md`).

## Run the calculations

With the extract in place, run the calculation scripts (they read `data\private\<extract>`, write `results\`):

```powershell
Get-Cohorts, Compare-AiCohorts -Labels, Get-Stage4bCohort, Get-Stage4bCodeContent, Get-AuthorBootstrap, Get-AuthorWeighted,
Get-AuthorRetention, Get-ReturningAuthors, Get-ModsVsAuthors, Get-QuarterlyAuthors, Get-GrowthByRelease, Get-NewMods,
Get-RepoAiSummary, Get-HiddenAiEstimate, Get-YouTubeRate, Get-ReleaseDownloadShare
```

Definitions are in each script's header and in METHODOLOGY.md.

## Verify the numbers

You can reproduce the published numbers if you have the extract of 2026-11-02:

1. Put the extract at `data\private\extract-2026-11-02-all\` (together with `data\private\audience\` if you want the audience check).
   A Windows directory junction does not need administrator rights and keeps the data outside the repository:
   `cmd /c mklink /J data\private <folder that contains extract-2026-11-02-all>` (`data\private` is git-ignored).
2. Run `scripts\Test-Reproduce.ps1`. It copies the scripts and the extract (without saved web pages) into a temporary work
   folder, so your private data and the published `results\` are never modified, re-runs the calculation scripts there and
   compares key numbers with the expected values written in the script. Per number it prints `PASS` or `FAIL`:
   `56% (25/45)` AI-early, `96% (43/45)` AI-late, `52.2%` for the rest plus AI-late, `80% (12/15)` for "no AI" declarations,
   `71.4% (70/98)` all declarers, `1,323` mods at 1.19, `549` AI-declaring mods, `262 of 3,411` authors, the author bootstrap
   interval `-11.6 .. +19.4` (seed 20261110, 10,000 resamples), cohort sizes and shares, code / content, hidden-AI thresholds and more.
3. Optional parameters: `-OverridesFile` (your private label-overrides file, to re-merge the labels and check the 549),
   `-CacheDir` (the cache, for the 34-mod download check), `-SkipBootstrap` (faster), `-KeepWork`.

Not re-run by the check (they need the network or the cache): the fetch and export scripts, the Wayback and repository scans,
`Get-CodeContent.ps1`. Their outputs are part of the extract. Two known tiny differences are documented in METHODOLOGY.md
("Known discrepancies"); the check expects them.
