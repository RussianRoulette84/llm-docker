---
description: Scout the codebase for a specific query
---

# Scout

Search the codebase to find relevant files and context for a given query.

## Variables

QUERY: $ARGUMENTS

## Workflow

1. IDENTIFY relevant search patterns based on the QUERY.
2. SEARCH content using grep:
   ```bash
   grep -r "QUERY" .
   ```
3. FIND matching files:
   ```bash
   find . -name "*QUERY*"
   ```
4. EXPLORE file structure if needed:
   ```bash
   ls -R apps/
   ```

## Report

Provide a list of relevant files and a brief summary of how they relate to the query.
