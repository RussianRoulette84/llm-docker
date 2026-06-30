# PLAN 01 — Deletion safety, stable sessions, cld/ocd de-dup, file splits

**Format:** Vanilla · **Mode:** YALO (phases 1→5 run autonomously, no "go" gates;
only the final phase needs the human for image rebuild + Mac test).

**Completion: ~97% — all refactor phases (1–5, 7) DONE; only Phase 6 (HUMAN rebuild + Mac test) remains.**

| Phase | Title | Status |
|---|---|---|
| 1 | Deletion-safe mounts + stable session identity | ✅ done |
| 2 | Universal `rm`→trash shim + builder-api trash job | ✅ done |
| 3 | Sweep `rm` from our scripts + regression guard | ✅ done |
| 4 | De-dup cld/ocd into setup.sh | ◐ ~70% (clean dedup done; `_maybe_start_api` deferred) |
| 5 | Split >200-line files (5A setup ✅ · 5B install ✅ · 5C jobs.py + server.py ✅) | ✅ done |
| 5H | HARDEN the splits (run-directly fix + 4 CI guards) | ✅ done |
| 7 | Finish deferred refactor (7A config/build_queue ✅ · 7B run-container ✅ · 7C launcher dedup ✅ · 7D entrypoint ✅) | ✅ done |
| 6 | Rebuild + host verification (HUMAN) | ☐ |

---

## Context

A real incident: user set `WORKSPACE_DIR=~/Projects` (was `~/Projects/ai`) and (1) the
whole `~/Projects` got wiped by an agent's `rm` propagating through the read-write
bind-mount, and (2) Claude lost all session memory because the container workdir is
derived from `basename(WORKSPACE_DIR)`. Root causes confirmed by exploration: rw mount
over the whole workspace; deny-rules are Claude-only (opencode/scripts/python bypass);
path-derived session identity. User decisions: RO workspace + RW current project;
universal `rm`→trash shim that routes to a builder-api host-trash job when inside the
project; **folder-name-only identity** (project token = `basename` of the repo root;
git is used only to locate that root, NOT for identity — git-remote keying was tried and
reverted because it lost memory on folder move/rename and broke for remote-less repos);
same basename under different parents (`~/Projects/ai/ProjectX` vs `~/Projects/ProjectX`)
→ same token → shared/merged memory; safety first.

Shared helpers already added to `setup.sh` (`_project_root`, `_project_token`,
`_compute_workspace_mounts`, `_dashed_session_dir`) — proven in simulation: `foo`
resolves to the same `/root/Projects/foo` under both `ai` and `Projects`; workspace `:ro`,
project `:rw`; escape hatch when launched at the workspace root.

---

## PHASE 1 — Deletion-safe mounts + stable identity
- [x] `setup.sh`: `_project_root`, `_project_token`, `_compute_workspace_mounts`,
      `_dashed_session_dir` (RO workspace + RW stable project; folder-name token).
- [x] `cld`: call `_compute_workspace_mounts`; emit `${_LLM_MOUNT_ARGS[@]}`; `-w
      $_LLM_DOCKER_WORKDIR`; label `llm-docker-project=$_LLM_PROJECT_TOKEN`; rewrite
      `_claude_session_dir`, slot-predict, tsv key (`_project_key`), save-session.
- [x] `ocd`: mirrored — `_compute_workspace_mounts`, `-w`, `${_LLM_MOUNT_ARGS[@]}`,
      label token, `_docker_workdir_for` via shared helper (sqlite `directory` now
      stable), tsv key + lookups via `_LLM_PROJECT_TOKEN`. Promoted `_project_key` +
      `_project_docker_workdir` to setup.sh.
- [x] `_validate_workspace_paths` (0E): dim one-liner in the RO branch — "workspace
      X is READ-ONLY, only <token> is writable (launch from the root for full write)".
- **Test:** `bash -n cld ocd setup.sh`; re-run the identity simulation for ocd's
      container-path + sqlite directory value; assert `ai` vs `Projects` give identical
      workdir token for a git project and a non-git project.

## PHASE 2 — Universal `rm`→trash shim + builder-api trash job
- [ ] `src/docker/rm-guard.sh`: installed to `/usr/local/bin/rm` by the entrypoint
      (shadows `/bin/rm` via PATH). Refuse protected roots (workspace target,
      `/root/Projects`, `/root/.claude`, `/root/.config`, mount points, `/`, `$HOME`);
      inside project → builder-api `POST /job/trash {path}` if API up, else container
      `trash`; never `/bin/rm` user data; allow real rm only for `/tmp/*`.
- [ ] `docker-entrypoint.sh`: install the shim early on PATH.
- [ ] `builder-api.host.toml.example` + `api_config/builder-api.toml`: add global
      `[jobs.trash]` (`command="trash"`, `{path}` anchored under project root).
- **Test:** `bash -n` the shim; table-driven dry-run of path classification
      (protected-root → refuse; project file → trash; `/tmp` → real rm); `python3` toml
      load of the new job; `dryrun=1` resolves the trash argv.

## PHASE 3 — Sweep `rm` from our scripts + regression guard ✅
- [x] Entrypoint cred-clears → `/bin/rm` (intentional, bypasses the shim). Host-side
      scratch deletes (`cld`/`ocd` handoff, `setup.sh` build-log + /tmp, `task.sh`) →
      explicit `/bin/rm`. `docker rm` / build-time image `rm` left (documented).
- [x] `scripts/ci/no-rm.sh` — fails on bare `rm` (allows `/bin/rm`, `docker rm`,
      `--rm`, `trash`); bash-3.2-safe; exempts shim + build-time files.
- [x] **Tested:** guard clean on tree, catches seeded `rm`, allows the 3 forms.

## PHASE 4 — De-dup cld/ocd into setup.sh  *(detailed)*

Confirmed still-duplicated (this session's grep): `_terminal_id`,
`_lookup_terminal_session`, `_write_secret_handoff`, `_teardown_builder_api`,
`_register_tmux_flip`, `_maybe_start_api`, plus the inline env-gorilla block.
(`_save_terminal_session` DIFFERS — cld jsonl vs ocd sqlite — keep tool-specific.)

- [x] **Byte-identical → lifted into `setup.sh`:** `_terminal_id`,
      `_lookup_terminal_session`, `_write_secret_handoff`, `_teardown_builder_api`,
      `_register_tmux_flip`, `_spawn_api_bg`. Removed from both launchers; all symbols
      resolve from setup.sh; `bash -n` clean. (ocd still inlines bg-spawn in 3 spots →
      swap to `_spawn_api_bg` when extracting `_maybe_start_api`.)
- [x] **env-gorilla re-exec → `src/setup/preflight.sh`.** Both launchers compute
      `_self_dir`, `source setup/preflight.sh`, then `SCRIPT_DIR="$_self_dir"`. Verified:
      args strip correctly, no spurious exec when env-gorilla absent, fallback warning
      fires. cld 1163→996, ocd 962→832.
- [ ] **DEFERRED: `_maybe_start_api` dedup + near-identical blocks.** Decision: leave
      `_maybe_start_api`/`run_*_container` tool-specific for now — they differ for real
      reasons (ocd orphan-precleanup, sqlite vs jsonl) and touch the just-fixed
      builder-api spawn. Marginal line savings vs real regression risk → defer.
- [ ] **`_maybe_start_api` → `setup.sh` with a `TOOL` arg** — fold ocd's orphan-daemon
      precleanup into a branch; keep the port resolution + spawn paths shared.
- [ ] **Near-identical → parametrize by `TOOL`:** docker-start+flock →
      `_ensure_docker_running TOOL`; rebuild prescan; clean-leftover →
      `_clean_leftover_containers TOOL`; multi-window spawn → `spawn_multi_windows TOOL …`.
- [ ] **Keep tool-specific:** `run_claude_container`/`run_opencode_container`,
      `_save_terminal_session` (jsonl vs sqlite), the arg-parse loops (different flags),
      `_claude_session_dir`/`_docker_workdir_for` (already thin → call shared helpers).
- **Test:** `bash -n cld ocd setup.sh setup/preflight.sh`; `diff` each extracted fn body
      against the pre-removal original; symbol smoke
      `bash -c 'WORKSPACE_DIR=; source setup.sh; for f in _terminal_id _maybe_start_api …; do type -t $f; done'`;
      re-run the identity + rm-classification sims to confirm no behavior drift.

## PHASE 5 — Split >200-line files  *(DETAILED — concrete module map)*

Target **~200 lines (sweet spot), 500 hard cap**. Loader pattern = `lib/ywizz/ywizz.sh`
(a thin file that `source`s its modules; order is irrelevant for function defs since
nothing is *called* until a launcher invokes it after sourcing). Done in 3 independently
verifiable sub-steps.

### 5A — `setup.sh` (1188) → `src/setup/` modules + thin loader
`setup.sh` is sourced by **cld, ocd, AND install.sh** → the loader MUST preserve every
function + the top-level setup (lines 1–21: `SCRIPT_DIR`, theme source, `RST/GRN/STEP_COLOR`).
Loader keeps that header + the var inits, then `source`s the modules below. Move (current
line ranges):
- [ ] `setup/banner.sh` — `_iterm_tag`, `_iterm_untag`, `llm-docker_version`, `print_banner` (24–86)
- [ ] `setup/log.sh` — `_log_ensure_dir/_file_size/_rotate_if_needed/_write_file`, `_log`, `_log_silent` (103–162)
- [ ] `setup/docker_log.sh` — `_docker_format_line`, `_docker_pretty`, `_count_*`, `_log_docker_exec` (163–595; ~430 = cohesive build-output prettifier, under the 500 cap — note in Concerns)
- [ ] `setup/config.sh` — `_tmux_nested_prompt`, `_read_env_var`, `_validate_workspace_paths`, `_source_all_config`, `setup_dirs`, `setup_env`, `_compute_cap_flags` (596–995, the non-identity/non-launcher bits)
- [ ] `setup/identity.sh` — `_project_root/_token/_compute_workspace_mounts/_dashed_session_dir/_project_key/_project_docker_workdir` (705–806)
- [ ] `setup/launcher.sh` — `_terminal_id`, `_lookup_terminal_session`, `_register_tmux_flip`, `_spawn_api_bg`, `_write_secret_handoff`, `_teardown_builder_api` (813–897)
- [ ] `setup/image.sh` — `_llm-docker_image_for_tool`, `setup_image`, `setup_image_incremental`, `run_setup` (996–1188)
- [ ] `setup/preflight.sh` — already done (sourced by launchers directly, NOT by the loader).
- **Test:** `bash -n setup.sh setup/*.sh`; `source setup.sh` then `type -t` every one of the
  ~30 functions resolves; re-run the identity + mount + rm sims; `bash -n cld ocd install.sh`.

### 5B — `install.sh` (799) → `src/install.d/` + thin driver
Steps run shared state (`NEW_WS`, `GORILLA_ENABLED`, …) → keep them in ONE shell scope by
`source`-ing step files in order (NOT subshells). Centralize numbering: `STEP_TOTAL=11` +
`_step "title"` helper that auto-increments and emits `header_tui "N/TOTAL title"` (kills the
hardcoded "N/11" brittleness).
- [ ] `install.d/00-helpers.sh` — `_update_kv/_update_env_var/_update_conf_var`, `_mask_secret`, `_mark_rebuild_needed`, `link_cmd`, `_u`, `_step`.
- [ ] `install.d/01-docker.sh` … `11-link.sh` — one file per step (each its executable block, now `_step "Checking Docker"` etc.).
- [ ] `install.sh` driver: bootstrap (clone), source ywizz + setup.sh + `install.d/00-helpers.sh`, set `STEP_TOTAL`, source `install.d/NN-*.sh` in order, then the completion banner block.
- **Test:** `bash -n install.sh install.d/*.sh`; source-smoke that helper symbols resolve;
  static check the step files reference only vars defined earlier in the chain.

### 5C — builder-api Python: `server.py` (942) + `jobs.py` (812)
Keep the public API stable so callers (`run-local.sh` execs `server.py`; modules
`import jobs`) don't change.
- [ ] `server.py` → `app_context.py` (`AppContext` + config watch/reload, 73–237) ·
      `http_handler.py` (`BuilderHandler`: `do_*`, `_dispatch*`, `_maybe_auth`,
      `_read_json_body`, `_serve_json`, `log_message`) · `routes.py` (a `RoutesMixin` class
      holding every `_ep_*`; `BuilderHandler(RoutesMixin, BaseHTTPRequestHandler)`).
      `server.py` stays the entry point — thin: imports + `_is_truthy_query`, `_parse_args`,
      `main` (804–942).
- [x] **`jobs.py` (812) → split + thin aggregator (done, verified).** Used sibling modules
      (no package/deletion): `jobs_errors.py` (96), `jobs_models.py` (constants+Placeholder+Job, 124),
      `jobs_parse.py` (354); `jobs.py` (246) keeps validate+command and RE-EXPORTS the public
      API so `import jobs` / `from jobs import …` are unchanged. Verified: all compile, public
      API complete, config.py's import works, and a FUNCTIONAL smoke (parse → validate →
      regex-reject → resolve_command) exercises real method bodies (catches missing imports).
- [x] **`server.py` (942) → split + thin entry (done, verified).** `app_context.py` (190,
      AppContext+config-watch) · `routes.py` (358, `RoutesMixin` with all `_ep_*` + `_is_truthy_query`) ·
      `http_handler.py` (261, `BuilderHandler(RoutesMixin, BaseHTTPRequestHandler)` + dispatch/auth/IO) ·
      `server.py` (163, thin entry: imports + `_parse_args` + `main`). Verified: import chain,
      MRO mixes RoutesMixin, all dispatch+`_ep_*` present, config.py import intact, AND an
      AST undefined-name audit that CAUGHT TWO real missing imports (`os` in http_handler,
      `sys` in jobs_parse) — both fixed. Added `scripts/ci/check-py.sh` (py_compile + AST
      audit) as a permanent 4th guard.
- [ ] ~~`jobs.py` → `jobs/` package~~ (superseded by the sibling-module approach above)
      (so `import jobs` / `from jobs import …` is unchanged): `errors.py` (exception classes
      60–159) · `models.py` (`Placeholder`, `Job` 160–260) · `parse.py` (`parse_jobs`,
      `_parse_hub_job`, `_parse_one_job`, `_parse_one_placeholder` 261–612) · `validate.py`
      (`validate_and_substitute` 613–694) · `command.py` (`resolve_command`,
      `compute_command_sha256`, `verify_command_hash` 695–787).
- **Test:** `python3 -m py_compile` every module; `python3 -c 'import server'` (exercises the
  whole import chain) + `_parse_args(['--project','x'])` round-trip; `python3 -c 'import jobs;
  jobs.validate_and_substitute; jobs.parse_jobs'`; watch for circular imports.

### Phase 5 exit
- [ ] `wc -l src/**` — every runtime file ≤ 500 (target 200); list any legit exceptions
      (e.g. `docker_log.sh`) in Concerns. Update plan checkmarks + completion %.

## PHASE 5-HARDEN — make the split durable + fix the one regression *(current)*

Probe found: setup modules are clean function defs EXCEPT (a) `setup/image.sh` ends with
the `if [[ "${BASH_SOURCE[0]}"=="${0}" ]]; then run_setup; fi` run-directly trailer — after
the split it can never fire for `./setup.sh` (the guard now lives in a module, not the
loader); (b) `banner.sh`/`log.sh` have harmless top-level var inits (order preserved). Loaders
`source` modules with no existence check → a missing/renamed module fails cryptically.

- [ ] **H1 — fix the standalone-run regression.** Move the `if BASH_SOURCE==0 → run_setup`
      trailer from `setup/image.sh` to the END of the `setup.sh` loader so `./setup.sh`
      behaves as the monolith did. (setup.sh is only ever *sourced* today, so zero runtime
      impact — this restores intended-but-latent behavior.)
- [ ] **H2 — fail-loud loaders.** `setup.sh` loader + `install.sh` driver: before each
      `source`, check the module/step file exists; on miss, print a clear
      `setup: missing module <x>` / `install: missing step <x>` and exit non-zero (vs the
      cryptic bash "No such file"). Catches a future rename/typo immediately.
- [ ] **H3 — module-integrity CI guard** (`scripts/ci/check-modules.sh`, bash-3.2-safe):
      (1) `source setup.sh` in a subshell, assert a PINNED list of the ~38 expected
      functions are all `declare -F`-present (fail if any missing/dropped);
      (2) concat `install.d/*` in sourcing order + `bash -n` (the combined flow parses);
      (3) forward-ref check — no `install.d` step CALLS a function first DEFINED in a
      later-sourced step.
- [ ] **H4 — behavior-drift regression test** (folded into the guard or
      `scripts/ci/check-behavior.sh`): source the REAL modular `setup.sh` and assert the
      identity sim (`ai` vs `Projects` → same `/root/Projects/foo`, workspace `:ro`),
      `_compute_cap_flags`, and the `rm-guard` classification all still produce the pinned
      expected outputs — so a future module edit that changes behavior fails loudly.
- [ ] **H5 — line-cap advisory** (`scripts/ci/check-size.sh`): list runtime shell+py files
      over 500; ADVISORY (exit 0) with the known-pending offenders (`cld`, `ocd`,
      `server.py`, `jobs.py`, `docker_log.sh`) annotated, so NEW growth is visible without
      blocking the still-pending 5C / run-container splits.
- **Test:** run all three CI guards (clean pass); `bash -n` everything; `./setup.sh` dry
  (sourced vs would-run-directly) behaves right; seed a deliberately-missing module and
  confirm H2 errors clearly; seed a dropped function and confirm H3 fails.

**5H RESULT (✅ done):** H1 trailer moved to the loader; H2 fail-loud in setup.sh loader +
install.sh driver (verified: missing module → clear error); H3+H4 `scripts/ci/check-modules.sh`
(38/38 fns, install.d reconstructs, no forward-refs, identity behavior pinned — all green);
H5 `scripts/ci/check-size.sh` advisory (also flagged 3 EXTRA over-cap files for future:
`docker-entrypoint.sh` 545, `config.py` 719, `build_queue.py` 737).

## PHASE 7 — Finish the deferred refactor *(planned — FULL scope, safest-first)*

Closes the remaining over-cap files + the deferred launcher dedup. All 4 CI guards
(`no-rm`, `check-modules`, `check-py`, `check-size`) back this. Ordered by risk.

### 7A — Python over-cap splits ✅ DONE
Result: `config.py` 719 → `config.py` (273) + `config_models.py` (110) + `config_parse.py`
(352); `config.load` against the repo shards resolves 14 jobs. `build_queue.py` 737 →
`build_queue.py` (522, cohesive `BuildQueue` class — accept just-over-cap) + `build_models.py`
(129, constants+QueueFull+BuildEntry+_iso/_elapsed) + `build_helpers.py` (113). All public
imports unchanged. `check-py` caught 3 real missing imports (sys/time/threading) → fixed;
hardened `check-py` with an `import server` smoke (catches class-body names the AST misses).
- [x] `config.py` (719) → `config_models.py` (dataclasses `BuildCfg/RuntimeCfg/EventsCfg/
      SecurityCfg/VerbSpec/Config/ConfigError`, 60–162) · `config_parse.py` (toml read +
      shard merge + verb parse: `_read_toml`, `_merge_project_shards`, `_check_shard_safety`,
      `_merge_project_block`, `_expand_env`, `_parse_verbs`, `_warn_stale_plugin`,
      `_resolve_in_root`) · `config.py` (`load`, `_resolve_project_view`, `_default_*` +
      **re-export** `load`/`Config`/`ConfigError`). Public API for `import config as _config`
      unchanged.
- [ ] `build_queue.py` (737) → `build_models.py` (`QueueFull` + `BuildEntry`, 37–128) ·
      `build_helpers.py` (module funcs `_short_id/_fingerprint/_iso/_elapsed/
      _resolve_managed_container/_kill_process_group/_tail_text`, 622–730) · `build_queue.py`
      (`BuildQueue` class ~490 + **re-export** `QueueFull`, `BuildEntry`). Keeps
      `from build_queue import BuildQueue, QueueFull` (server + routes) working.
- **Test:** `check-py` (compile + undefined-name AST audit) · `python3 -c 'import server,
      config, build_queue'` · a `config.load` smoke against the sample toml.

### 7B — cld/ocd: extract `run_*_container` to sourced files ✅ DONE
Result: cld 996→751 + `cld.run.sh` (254); ocd 832→638 + `ocd.run.sh` (203). Fail-loud
source guards; `bash -n` clean; functions resolve when sourced; 1 call / 0 def each.
- [x] `cld` `run_claude_container` (706–996, ~290 ln) → `cld.run.sh`; `cld` sources it after
      `setup.sh`. Same for `ocd` `run_opencode_container` (462–832) → `ocd.run.sh`.
      Tool-specific bodies stay separate (not deduped) — just relocated, like the setup
      modules. cld → ~706, ocd → ~462.
- **Test:** `bash -n cld ocd cld.run.sh ocd.run.sh`; source-smoke that `run_*_container`
      resolves; identity sim unchanged.

### 7C — `_maybe_start_api` dedup ✅ DONE · near-identical blocks remaining
**`_maybe_start_api` unified** into `setup/launcher.sh:_maybe_start_api TOOL project_dir`
(TOOL-gated `_log`, shared `_spawn_api_bg`, folded in ocd's orphan-precleanup for both).
Removed from both launchers + cld's now-unused `_status`. cld 751→631, ocd 638→514.
**Spawn-path guard PASSED:** stubbed `osascript`, captured argv for CLD vs OCD — byte-identical
and shape-matched the pre-refactor invocation. All 4 guards green (check-modules pins 39 fns).
The 61 "divergent" lines were comments + log tags + the precleanup — the osascript call was
already identical, so the dedup carried no real spawn risk.
- [x] Unify into `setup.sh:_maybe_start_api TOOL project_dir` — TOOL-gated logging, always
- [x] **docker-start+flock → `setup/docker.sh:_ensure_docker_running TOOL`** + **multi-window
      → `setup/launcher.sh:spawn_multi_windows TOOL`.** Both parametrized + verified (dry-runs,
      spawn-path re-confirmed). cld 996→537, ocd 832→**419 (under cap)**. clean-leftover (~14 ln)
      skipped — marginal; cld stays 537 (entry-point launcher, accepted over the advisory cap).
      use the shared `_spawn_api_bg`, fold the orphan-precleanup in. Swap ocd's 3 inline
      bg-spawns to `_spawn_api_bg`.
- [ ] Parametrize the other near-identical blocks → `setup.sh`: docker-start+flock →
      `_ensure_docker_running TOOL`; clean-leftover → `_clean_leftover_containers TOOL`;
      multi-window spawn → `spawn_multi_windows TOOL …`.
- **Spawn-path guard (mandatory):** before/after, dry-run `_maybe_start_api` with `osascript`
      stubbed to ECHO its argv; assert the `builder_api.applescript` invocation (launcher,
      project_dir, mode, port, handoff, status_cmd) is **byte-identical** per TOOL to the
      pre-refactor command. Plus `check-modules` (extend the pinned fn list), identity sim,
      `bash -n`, `no-rm`. cld/ocd drop under/near the cap.

### 7D — `docker-entrypoint.sh` (545) → helpers + lib ✅ DONE
Extracted the 5 helper fns (`cleanup`, `_save_claude_slot_session`,
`_save_opencode_slot_session`, `_exit_or_drop_to_shell`, `_launch_tmux_team`, lines 8–195)
→ `docker/entrypoint-lib.sh` (196); entrypoint (366) sources it fail-loud from
`/usr/local/bin/entrypoint-lib.sh`. **Delivery mirrors the entrypoint exactly** (it's both
baked AND bind-mounted): added Dockerfile `COPY docker/entrypoint-lib.sh …` + `chmod`, and a
bind-mount in BOTH `cld.run.sh`/`ocd.run.sh` beside the existing entrypoint + rm-guard mounts
— so lib edits take effect without a rebuild, same as the entrypoint. Verified: `bash -n`
both; sourced lib provides all 5 helpers; 4 guards green; entrypoint OFF the over-cap list.
Runtime confirmation (the source path inside the container) waits for Phase 6.

### Phase 7 exit
- [ ] Re-run all 4 guards green; `check-size` shows only intended remainders; update plan.

## PHASE 6 — Rebuild + host verification (HUMAN — last phase only)
- [ ] User: `cld --build` (entrypoint + rm-shim need a rebuilt image).
- [ ] User Mac checks: `WORKSPACE_DIR=~/Projects`, `cd ~/Projects/<p> && cld` → `rm -rf
      /root/Projects` and sibling refused; project edits ok; `rm file` → host Trash;
      flip `WORKSPACE_DIR` → `cld -c` / `ocd -c` resume; `cld -a` panels + teardown.

---

## Notes
- **Phase 4/5 decisions:** env-gorilla block → extracted to `setup/preflight.sh`;
  Phase 5 scope is FULL — shell (`setup/` modules) + `install.d/` + Python daemon split.
- Phases 1–5 are shell/python only → self-verified here with `bash -n`, `py_compile`,
  and logic simulations. No Docker/Mac needed until Phase 6.
- Canonical working copy of this plan will be mirrored to `./plans/01-safety-dedup.md`
  in the repo at build start and kept updated with checkmarks + completion %.
- Save the YALO workflow itself to memory (feedback) so future sessions follow it.
