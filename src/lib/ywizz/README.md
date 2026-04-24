# ywizz TUI library

TUI helper for interactive wizards and prompts.

## TUI helpers

**Input / choice (wizard steps):**

- `ask_tui` — free-text line input
- `ask_yes_no_tui` — yes/no
- `select_tui` — single choice from a list
- `ask_path_tui` — path input (wraps `ask_tui`)
- `checklist_tui` — multi-choice

**Display / flow:**

- `header_tui` — section header
- `header_tui_collapse` — collapsible header
- `print_loading_header_tui` — loading header
- `wait_for_condition_tui` — progress/wait with progress bar

(`print_progress_bar_tui` is used internally by `wait_for_condition_tui` and is not a direct wizard-step helper.)

## Declarative usage (`ywizz_show`)

Wizard steps can be driven from a single entry point with key=value arguments instead of calling each TUI helper directly. Used in `install_clawfather.sh` and elsewhere.

**Entry point:** `ywizz_show type=... [title=] [out=] [default=] [options=] ...`

**Types:** `confirm` | `path` | `input` | `select` | `checklist` | `header` | `security` | `ascii` | `banner`

**Common parameters:**

| Parameter       | Meaning                                      | Used by              |
|----------------|----------------------------------------------|----------------------|
| `type=`        | Step kind (required)                         | all                  |
| `title=`       | Prompt or heading text                       | confirm, path, input, select, checklist, header |
| `out=`         | Variable name to write the result into       | confirm, path, input, select, checklist |
| `default=`     | Default value or index                       | confirm, path, input, select |
| `options=`     | Pipe-separated options (e.g. `A|B|C`)        | select, checklist    |
| `descriptions=`| Pipe-separated description lines             | select, checklist    |
| `subtitles=`   | Pipe-separated subtitle lines                | select, checklist    |
| `initial=`     | Initial checklist state                      | checklist            |
| `which=`       | e.g. `primary` for ascii/banner variant      | ascii, banner        |

**Examples for each type:**

```bash
# --- Display only (no input) ---
ywizz_show type=ascii which=primary          # or which=secondary
ywizz_show type=banner which=primary         # or which=secondary (shows combined banner)
ywizz_show type=security                     # security warning block
ywizz_show type=header title="Section name"

# --- Yes/No ---
ywizz_show type=confirm title="Continue?" out=confirm default=y
[[ "$confirm" == "n" ]] && exit 0

# --- Free-text line ---
ywizz_show type=input title="Your name" default="Alice" out=name

# --- Path ---
ywizz_show type=path title="Project directory" default="$HOME/project" out=project_dir

# --- Single choice (default=0 is first option) ---
ywizz_show type=select title="Mode" options="Local|Remote|Both" out=mode default=0
# With descriptions/subtitles (same pipe count as options):
# options="A|B" descriptions="Desc A|Desc B" subtitles="Sub A|Sub B"

# --- Multi-choice (initial=comma-separated 0-based indices) ---
ywizz_show type=checklist title="Features" options="SSH|Docker|K8s" descriptions="SSH access|Docker socket|Kubernetes" initial=0,2 out=FEATURES
# Result: FEATURES_0, FEATURES_1, FEATURES_2 (y/n per option)
```

For `select` and `checklist`, use `options="A|B|C"` (pipes become newlines). You can still call the individual TUI helpers (`ask_tui`, `select_tui`, etc.) directly when you need more control (e.g. custom tree prefix or continuation flags).
