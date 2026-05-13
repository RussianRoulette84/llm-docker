---
description: Generate a Yaro-style CHANGELOG.md entry for the current uncommitted/staged work. Show it in chat, then ask whether to write it to CHANGELOG.md.
argument-hint: [optional: version override, e.g. "2.5" — defaults to last_version + 0.1]
allowed-tools: Bash, Read, Edit, Write, mcp__git__git_status, mcp__git__git_diff, mcp__git__git_log
---

# GIT — changelog entry (llm-docker style)

Generate a changelog block in **Yaro's house style** (matches the existing `./CHANGELOG.md` in this repo) for the current branch's uncommitted / staged / recent work, then ask whether to prepend it to `CHANGELOG.md`.

**No git mutations.** Do not run `git add` / `commit` / `push`. The user commits manually.

## Variables

MODE + VERSION (resolution order):

1. **`$ARGUMENTS` is a version like `2.5`** → MODE = `new`, VERSION = `2.5`. Creates a brand-new top entry with that version + today's date.
2. **`$ARGUMENTS` is `new`** → MODE = `new`, VERSION = (latest in CHANGELOG.md + 0.1). For a fresh release with auto-bumped minor.
3. **`$ARGUMENTS` empty (default)** → read the latest `# v<X.Y> (<DATE>)` heading from `CHANGELOG.md`:
   - DATE == today (release in-progress) → MODE = `append`, VERSION = the existing version. Bullets get **merged into the existing entry**, not duplicated.
   - DATE < today (latest release already shipped) → MODE = `new`, VERSION = latest + 0.1.
4. **`CHANGELOG.md` doesn't exist** → MODE = `new`, VERSION = `0.1`.

DATE: today, `YYYY-MM-DD`.

Releases are not version-bumped on every changelog edit — the same `# vX.Y (TODAY)` block accumulates bullets across a workday until the user manually tags it shipped.

## House style — copy this exactly

- Top heading: `# v<VERSION> (<DATE>)` — e.g. `# v2.5 (2026-05-13)`. **Not** the date-author shape used by other projects.
- One short intro paragraph describing the gist of the release (1-2 sentences, plain English).
- `## Section Name` for each user-facing area touched. Section names follow the existing repo convention — examples actually used in this CHANGELOG.md:
  - `## Builder API — security`
  - `## Builder API — concurrency / reliability`
  - `## Builder API — visuals`
  - `## llm-docker cage`
  - `## Browsing`
  - `## Stability`
  - `## Security`
  - `## New cld / ocd flags`
  - `## Setup & Install`
  - `## Daemon stability`
  - `## Shell & UX`
  - Pick what fits the current batch — don't invent generic ones like "Misc" if a real area name applies.
- `### Dev logs` ALWAYS LAST — internal/technical work (refactors, build/CI, dep pins, file restructure, doc rewrites). Use it freely for anything that isn't a user-visible behavior change.
- Bullets start with **one tag in square brackets**, then plain English:
  - `[NEW]` new feature
  - `[BUG]` bug squashed (past tense: "was crashing", "is fixed")
  - `[BUG?]` maybe a bug — needs investigation
  - `[CHANGE]` request to change existing behavior
  - `[TWEAK]` polish / make existing thing better
- **Plain English.** Translate jargon ("regex catastrophic backtrack" → "endpoint was hanging on long responses"). In user-facing sections, mention pages / commands / flags, NOT file paths or function names. Dev logs may include code paths.
- **Past tense for fixes** ("was breaking", "is fixed").
- One blank line after the version heading.
- No "TODO" / "Notes for X" footers — pure changelog only.

## What NOT to include — STOP SPAMMING

Inclusion test: would a USER of llm-docker experience this differently from the previous release? If not, it's noise. Leave it out. When in doubt, leave it out.

Specifically NEVER bullet:

- **Private `.claude/commands/*` files** — per-project customisations. Readers don't have them.
- **`CLAUDE.md` / `AGENTS.md` / project house-rules** — internal authoring, not product.
- **Pure docs churn** — README typo fixes, `docs/*.md` rewrites that don't ship a new behavior. If a doc changed because a feature changed, log the FEATURE, not the doc. The doc isn't the news.
- **`CHANGELOG.md` itself.**
- **`.Trash-*` shuffling** — moves don't equal changes.
- **`.gitignore` micro-tweaks** — too small to matter, unless they intentionally relax/tighten what's committed in a way users notice.
- **Refactors that don't change behavior** — go in dev logs ONLY if they materially affect future contributors. Most don't; skip.

If a session's entire output is in those categories → reply "nothing changelog-worthy in this batch" and STOP. Don't manufacture bullets to fill the entry.

## Workflow

1. **Resolve MODE + VERSION + DATE.** Per the rules above. State the resolved values in chat before showing the entry:
   - "**Append to v2.4** (latest, today's date) — merging into existing entry." or
   - "**New release v2.5** (date < today, auto-bumped)." or
   - "**New release v2.5** (forced via `$ARGUMENTS`)."
2. **Inspect what changed.** Run:
   - `git status --short` — untracked + modified
   - `git diff --stat` + `git diff --cached --stat` — sizes
   - For files small enough to digest (≤ ~150 lines), `git diff <file>` to understand the change. For larger ones, read the diff and summarize from headers/context.
   - `git log --oneline -5` — recent commits (in case the batch is partly committed already).
   - **APPEND MODE only**: also `Read CHANGELOG.md` (top ~80 lines) so you don't duplicate bullets that are already there. Cross-reference each candidate bullet against the existing v2.4 content.
3. **Group bullets by user-facing area.** Use `## <area>` headings. End with `### Dev logs`.
   - **APPEND MODE**: only emit bullets that aren't already in the existing entry. If a section (e.g. `## Builder API — visuals`) already exists in v2.4, new bullets go under the same heading; if a section is brand new, add it. Don't duplicate the intro paragraph — only emit NEW bullets.
4. **Plain-English bullets, tagged.** User-facing sections never mention file paths or function names; dev logs can.
5. **Print the changelog in chat**, wrapped in a `markdown` code fence:
   - **NEW MODE**: print the whole new top entry (heading + intro + sections + dev logs).
   - **APPEND MODE**: print ONLY the new bullets, grouped under their target section names. Mark sections as `## Builder API — visuals (existing)` or `## New section name (new)` so the user can see at a glance what's being added vs. extended.
6. **Ask the user**: "Apply to `CHANGELOG.md`? [yes / no / edit]"
   - `yes`:
     - **NEW MODE** → prepend the new entry to `CHANGELOG.md` (above the current top heading, separated by one blank line).
     - **APPEND MODE** → for each section: if it exists in v2.4, `Edit` to insert the new bullets at the end of that section (just before the next `##` or `###` heading). If the section doesn't exist yet, insert it just before the existing `### Dev logs` (so dev logs always stays last in the entry).
   - `no`: leave `CHANGELOG.md` untouched.
   - `edit`: invite the user to point out changes (section names? tag re-classifications? merge / split bullets?). Regenerate. Re-ask.
7. **Don't write files until the user says yes.** Don't run git commits. After writing (if approved), report what was added — DO NOT commit.

## Output format

```markdown
# v<VERSION> (<DATE>)

<one-line gist>

## <user-facing area>
- [TAG] plain-English line

## <another user-facing area>
- [TAG] plain-English line

### Dev logs
- [TAG] technical line (file paths ok here)
- [TAG] technical line
```

## Tone reminders

- Short. Sales reader for user-facing sections. No code paths in user-facing sections — only in `### Dev logs`.
- If a release is tiny (one bugfix), one section + one bullet is fine.
- If you can't infer what a diff means, say so honestly instead of guessing. Better to ask "what changed in `src/x/y.py`?" than invent a bullet.
- The CHANGELOG.md file is the source of truth for tone — when uncertain about section naming or bullet phrasing, read the most recent 2-3 entries and match their style.

After the entry is printed (and written, if approved), follow up with the standard reporting footer per `CLAUDE.md` (Request / Done / Success / Concerns / Optimizations / Hacks / Next steps).
