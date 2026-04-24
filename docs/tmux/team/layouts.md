# Team mode — layouts

Four layouts, picked by the `N` argument to `-tt`.

| Command      | Panes | Arrangement        |
|--------------|-------|--------------------|
| `cld -tt`    | 4     | 1 main + 3 stacked (default) |
| `cld -tt 2`  | 2     | side-by-side       |
| `cld -tt 3`  | 3     | 1 main + 2 stacked |
| `cld -tt 4`  | 4     | 2×2 grid           |

## Pane roles

- **Pane 0 (lead):** your default claude model — the "main" one you drive
- **Panes 1..N-2:** additional claude instances, same default model
- **Pane N-1 (last):** always runs Haiku (`claude --model haiku`) for cheap/fast tasks like grep summaries, "what does this file do", throwaway refactors

## Diagrams

```
-tt        -tt 2      -tt 3      -tt 4
+------+   +--+--+    +----+--+  +--+--+
|      |   |  |  |    |    |  |  |  |  |
| lead |   |  |  |    | ld |  |  |  |  |
|      |   |ld|hk|    |    |  |  +--+--+
+--+--++   |  |  |    +----+--+  |  |  |
|1|2|3 |   +--+--+    |hk  |  |  |  |  |
+-+-+--+              +----+--+  +--+--+
(last=hk)             (last=hk)  (last=hk)
```

## When each layout fits
- **default (1+3):** one driver + 3 helpers running parallel subtasks
- **2 (side-by-side):** pair a main session with a scratchpad/haiku
- **3 (1+2):** one driver + a read-only watcher + a haiku
- **4 (2×2 grid):** four equal-weight agents (ensemble-style work)

Environment variables piped into the container: `TMUX_TEAM=true`, `TMUX_TEAM_SIZE={0|2|3|4}` — see [src/cld:695-696](../../../src/cld#L695-L696).
