---
description: Prevent code bloat and technical debt from accumulating during iterative bug fixing.
---

## "Yay it works!" cleanup command

### Trigger detection
- Trigger phrases (case-insensitive): "it works", "works", "fixed", "works now", "yay", "yay it works".
- Trigger only if the user says one of those phrases AND there were more than 2 previous fix attempts by the assistant in the current session (an attempt = an edit/change applied by the assistant intended to fix the issue).

### Scope / definition of "recent changes":
- "Recent changes" = all edits and code changes performed by the assistant since the user first asked the assistant to fix or implement the target feature and the assistant repeatedly attempted fixes that failed to produce the expected outcome.

### Prompt (exact):
```
============= -+[ YAY! It's FINALLY working!!! ]+- =================

Clean up code? Reply with: [YES] or [NO]
```

If the user replies [NO]:
- Stop. Do not perform cleanup and continue with normal workflow.

If the user replies [YES]:
- Cleanup scope:
  - Target only obvious artifacts added during the fix attempts:
    - debug prints and ad-hoc logging added for troubleshooting,
    - ad-hoc fallbacks that duplicate logic,
    - commented-out experimental code,
    - redundant key-checks that materially duplicate code paths.
  - Do NOT change public APIs, database migrations, feature flags, telemetry, or behavior intentionally introduced for compatibility without explicit user approval.

- Safety & verification:
  - Run formatters, linters, and tests only if necessary or appropriate. If the repository lacks tests or running them is out of scope, proceed conservatively without them.
  - Do NOT perform any git operations (no branch creation, no commits, no pushes). Instead prepare an explicit patch/diff for user review.

- Workflow constraints:
  - Make minimal, focused edits and produce a patch (diff) or a staged set of file changes for the user to inspect.
  - If tests exist and are relevant, run them and include results in the patch metadata. If tests fail after cleanup, revert cleanup changes locally and present the failure details to the user.
  - Update existing tests if they obviously require small adjustments due to cleanup; do not create new tests.

- Acceptance criteria and final confirmation:
  - Present the cleanup changes and (if run) linter/test results to the user and prompt:
    ```
    ========================================================
    Still working?

    [YES] or [NO]
    ========================================================
    ```
  - If user replies [YES]: finalize — the user decides how to apply the patch.
  - If user replies [NO]: do not finalize — continue debugging/fixing as requested.