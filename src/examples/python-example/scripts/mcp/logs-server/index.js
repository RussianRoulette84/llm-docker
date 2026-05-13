#!/usr/bin/env node
// llm-docker-logs MCP — tail / grep / list / find-errors in the project's
// `logs/` directory. Project-agnostic; any project that writes to ./logs/*.log
// can use this as-is. Wire it into .mcp.json (see this project's .mcp.json).
//
// Tools:
//   - list_logs       list every *.log file under the project's log dirs
//   - tail_log        last N lines of a log
//   - grep_log        regex search with ±N context
//   - recent_errors   heuristic ERROR/Exception/Traceback/CRITICAL/FATAL scan
//
// Env:
//   MCP_REPO       project root (default: 3 levels up from this file)
//   MCP_LOG_DIRS   colon-separated list of log dirs relative to MCP_REPO
//                  (default: "logs")

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { readFile, readdir, stat } from "node:fs/promises";
import { resolve, join, basename } from "node:path";

const REPO = process.env.MCP_REPO || resolve(new URL("../../../..", import.meta.url).pathname);
const LOG_DIRS = (process.env.MCP_LOG_DIRS || "logs")
    .split(":")
    .map(d => resolve(REPO, d));

async function listLogFiles() {
    const out = [];
    for (const d of LOG_DIRS) {
        try {
            const entries = await readdir(d, { withFileTypes: true });
            for (const e of entries) {
                if (e.isFile() && e.name.endsWith(".log")) {
                    const p = join(d, e.name);
                    const s = await stat(p);
                    out.push({ path: p, name: e.name, bytes: s.size, mtime: s.mtime.toISOString() });
                }
            }
        } catch {}
    }
    return out.sort((a, b) => b.mtime.localeCompare(a.mtime));
}

function safePath(p) {
    const abs = resolve(p);
    if (!LOG_DIRS.some(d => abs === d || abs.startsWith(d + "/"))) {
        throw new Error(`path outside log dirs: ${abs}`);
    }
    return abs;
}

async function tailLog(path, lines = 200) {
    const abs = safePath(path);
    const buf = await readFile(abs, "utf8");
    return buf.split(/\r?\n/).slice(-lines).join("\n");
}

async function grepLog(path, pattern, ctx = 0) {
    const abs = safePath(path);
    const buf = await readFile(abs, "utf8");
    const all = buf.split(/\r?\n/);
    const re = new RegExp(pattern, "i");
    const hits = [];
    for (let i = 0; i < all.length; i++) {
        if (re.test(all[i])) {
            hits.push(all.slice(Math.max(0, i - ctx), Math.min(all.length, i + ctx + 1)).join("\n"));
        }
    }
    return hits.length ? hits.join("\n---\n") : "(no matches)";
}

async function recentErrors(perFile = 20) {
    const files = await listLogFiles();
    const chunks = [];
    for (const f of files) {
        try {
            const buf = await readFile(f.path, "utf8");
            const errs = buf.split(/\r?\n/)
                .filter(l => /ERROR|Exception|Traceback|CRITICAL|FATAL/i.test(l));
            if (errs.length) chunks.push(`### ${basename(f.path)}\n${errs.slice(-perFile).join("\n")}`);
        } catch {}
    }
    return chunks.length ? chunks.join("\n\n") : "(no recent errors)";
}

const server = new Server(
    { name: "llm-docker-logs", version: "0.1.0" },
    { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [
        {
            name: "list_logs",
            description: "List every *.log file in the project's log dirs (size + mtime).",
            inputSchema: { type: "object", properties: {} }
        },
        {
            name: "tail_log",
            description: "Tail last N lines of a log file (default 200).",
            inputSchema: {
                type: "object",
                properties: {
                    path:  { type: "string", description: "Absolute path; must be under a configured log dir." },
                    lines: { type: "number", description: "How many lines to tail (default 200)." }
                },
                required: ["path"]
            }
        },
        {
            name: "grep_log",
            description: "Grep a log file by regex with ±N context lines.",
            inputSchema: {
                type: "object",
                properties: {
                    path:    { type: "string" },
                    pattern: { type: "string", description: "JavaScript regex (case-insensitive)." },
                    ctx:     { type: "number", description: "Context lines on each side (default 0)." }
                },
                required: ["path", "pattern"]
            }
        },
        {
            name: "recent_errors",
            description: "Recent ERROR/Exception/Traceback/CRITICAL/FATAL lines across all logs.",
            inputSchema: {
                type: "object",
                properties: {
                    perFile: { type: "number", description: "Max lines per file (default 20)." }
                }
            }
        }
    ]
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const { name, arguments: args = {} } = req.params;
    try {
        switch (name) {
            case "list_logs":
                return { content: [{ type: "text", text: JSON.stringify(await listLogFiles(), null, 2) }] };
            case "tail_log":
                return { content: [{ type: "text", text: await tailLog(args.path, args.lines ?? 200) }] };
            case "grep_log":
                return { content: [{ type: "text", text: await grepLog(args.path, args.pattern, args.ctx ?? 0) }] };
            case "recent_errors":
                return { content: [{ type: "text", text: await recentErrors(args.perFile ?? 20) }] };
            default:
                throw new Error(`unknown tool: ${name}`);
        }
    } catch (e) {
        return { content: [{ type: "text", text: `ERROR: ${e.message}` }], isError: true };
    }
});

await server.connect(new StdioServerTransport());
