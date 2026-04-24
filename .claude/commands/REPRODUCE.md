---
description: Reproduce a bug and document steps - does NOT fix, prepares resolution file
---

# Reproduce Bug

Reproduce a reported bug and document the reproduction steps. This command does NOT fix the bug - it prepares a resolution file for later implementation.

## Variables

BUG_DESCRIPTION: $ARGUMENTS

## Instructions

- IMPORTANT: You are documenting, not fixing
- Reproduce the bug to verify it exists
- Document exact steps to reproduce
- Capture relevant error messages and logs
- Identify root cause if possible
- Save resolution file to `reviews/`

## Workflow

1. READ the bug description from BUG_DESCRIPTION
2. Identify relevant files using Glob and Grep
3. Reproduce the issue locally:
   - Start the app if needed
   - Follow reported steps
   - Verify the bug occurs
4. Document reproduction:
   - Exact steps to trigger
   - Expected vs actual behavior
   - Error messages / stack traces
   - Screenshots or logs if relevant
5. Analyze root cause:
   - Identify the problematic code
   - Note potential fix approaches
   - Do NOT implement the fix
6. Write resolution file to `reviews/bug-{descriptive-name}-resolution.md`

## Resolution File Format

```md
# Bug Resolution: <bug name>

## Status
Reproduced: Yes/No
Date: <date>

## Reproduction Steps
1. <step 1>
2. <step 2>
3. <step 3>

## Expected Behavior
<what should happen>

## Actual Behavior
<what actually happened>
## Error Logs / Stack Traces
<paste logs here>

## Root Cause Analysis
<analysis of why this is happening>

## Potential Fixes
<approaches to fix, do not implement>
```
