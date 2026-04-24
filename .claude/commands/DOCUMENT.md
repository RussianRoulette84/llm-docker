---
description: Generate documentation or specifications for code
---

# Document

Generate comprehensive documentation or specifications for the specified code target.

## Variables

TARGET: $ARGUMENTS

## Workflow

1. EXPLORE the target
   - If `TARGET` is a directory, list files to identify structure.
   - If `TARGET` is a file, read its content.

2. ANALYZE the code
   - Identify modules, classes, functions, and parameters.
   - Extract existing docstrings and comments.
   - Infer types and behavior where explicit documentation is missing.

3. DETERMINE output location
   - **General Documentation**: Store in `docs/` (e.g., `docs/{component}_docs.md`)
   - **Specifications/Requirements**: Store in `specs/` (e.g., `specs/{feature}_spec.md`)

4. GENERATE content
   - Produce a Markdown report containing:
     - **Overview**: High-level summary.
     - **Components**: Detailed breakdown.
     - **Usage**: Examples.

## Report

Return the path to the generated documentation/specification file.
