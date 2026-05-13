#!/usr/bin/env node
// llm-docker-ops MCP — thin proxy to the host-side builder-api daemon.
// Every command runs on your Mac via the host config (~/.llm-docker/builder-api.toml).
// This MCP server is project-agnostic; the SAME file works in any project.
//
// Tools:
//   - list_jobs        what jobs the daemon will accept for this project
//   - run_job          POST /job/<name>   (with optional `params`)
//   - queue            GET  /queue        (current + pending + history + total_history)
//   - cancel_pending   DELETE /queue/<id>
//   - cancel_current   DELETE /current/cancel
//   - runtime_status   GET  /status
//   - run / stop       POST /run, /stop   (long-lived runtime process)
//   - builder_api      raw proxy for power users
//
// Env:
//   BUILDER_API_HOST      hostname for the daemon (default host.docker.internal)
//   BUILDER_API_PORT      port (default 6666, but each project usually has its own)
//   BUILDER_API_PASSWORD  X-Builder-API-Password header value (set in your shell)

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import http from "node:http";
import https from "node:https";
import { URL } from "node:url";

const BUILDER_HOST = (process.env.BUILDER_API_HOST || "host.docker.internal").replace(/^"|"$/g, "");
const BUILDER_PORT = process.env.BUILDER_API_PORT || "6666";
const BUILDER_BASE = process.env.BUILDER_API_BASE || `http://${BUILDER_HOST}:${BUILDER_PORT}`;
const BUILDER_PASS = process.env.BUILDER_API_PASSWORD || "";

// node's `fetch` (undici) blocks port 6666 as a legacy "unsafe" IRC port even
// though that's the builder-api's default. Use node:http directly.
function rawRequest(urlStr, { method = "GET", headers = {}, body = null, timeoutMs = 60_000 } = {}) {
    return new Promise((resolve, reject) => {
        const u = new URL(urlStr);
        const lib = u.protocol === "https:" ? https : http;
        const opts = {
            hostname: u.hostname,
            port:     u.port || (u.protocol === "https:" ? 443 : 80),
            path:     u.pathname + u.search,
            method,
            headers:  { ...headers }
        };
        if (body) opts.headers["Content-Length"] = Buffer.byteLength(body);
        const req = lib.request(opts, (res) => {
            let data = "";
            res.on("data", (c) => { data += c; });
            res.on("end", () => resolve({ status: res.statusCode, text: data }));
        });
        req.on("error", reject);
        req.setTimeout(timeoutMs, () => { req.destroy(new Error("timeout")); });
        if (body) req.write(body);
        req.end();
    });
}

async function callBuilder(path, { method = "GET", body = null } = {}) {
    const headers = { "X-Builder-API-Password": BUILDER_PASS };
    const bodyStr = body ? JSON.stringify(body) : null;
    if (bodyStr) headers["Content-Type"] = "application/json";
    try {
        const r = await rawRequest(`${BUILDER_BASE}${path}`, { method, headers, body: bodyStr });
        return `${method} ${BUILDER_BASE}${path}\nstatus=${r.status}\n${r.text}`;
    } catch (e) {
        return `ERROR builder-api unreachable at ${BUILDER_BASE}: ${e.message}\n` +
               `Hint: is the daemon running? Try \`cld -a\` in the project root, or check ~/.llm-docker/builder-api.toml has a [project.<this-project>] block.`;
    }
}

// ─── tool implementations ──────────────────────────────────────────────

async function list_jobs()      { return callBuilder("/jobs"); }
async function queue()          { return callBuilder("/queue"); }
async function runtime_status() { return callBuilder("/status"); }
async function cancel_current() { return callBuilder("/current/cancel", { method: "DELETE" }); }
async function run()            { return callBuilder("/run",  { method: "POST" }); }
async function stop()           { return callBuilder("/stop", { method: "POST" }); }

async function run_job(args = {}) {
    if (!args.name) return "ERROR: name required. Call list_jobs first to see what's available.";
    return callBuilder(`/job/${args.name}`, { method: "POST", body: { params: args.params || {} } });
}

async function cancel_pending(args = {}) {
    if (!args.id) return "ERROR: id required (use queue to find pending queue ids).";
    return callBuilder(`/queue/${args.id}`, { method: "DELETE" });
}

async function builder_api(args = {}) {
    // Power-user escape hatch — call any builder-api endpoint directly.
    return callBuilder(args.path || "/queue", {
        method: (args.method || "GET").toUpperCase(),
        body:   args.body || null
    });
}

// ─── MCP wiring ───────────────────────────────────────────────────────

const TOOLS = [
    { name: "list_jobs",      desc: "List all jobs available for this project (GET /jobs).",                              fn: list_jobs,      schema: {} },
    { name: "queue",          desc: "Inspect builder-api queue (current + pending + history + total_history).",          fn: queue,          schema: {} },
    { name: "runtime_status", desc: "Get runtime process status (GET /status — PID, uptime, current build).",            fn: runtime_status, schema: {} },
    {
        name: "run_job",
        desc: "Run a host-defined job by name (POST /job/<name>).",
        fn: run_job,
        schema: {
            type: "object",
            properties: {
                name:   { type: "string", description: "Job name (call list_jobs to see what's available)." },
                params: { type: "object", description: "Placeholder values for parameterized jobs." }
            },
            required: ["name"]
        }
    },
    {
        name: "cancel_pending",
        desc: "Cancel a pending build by queue id (DELETE /queue/<id>).",
        fn: cancel_pending,
        schema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
    },
    { name: "cancel_current", desc: "Cancel the running build (DELETE /current/cancel).", fn: cancel_current, schema: {} },
    { name: "run",            desc: "Start or restart the project's long-lived runtime process (POST /run).", fn: run, schema: {} },
    { name: "stop",           desc: "Stop the project's runtime process (POST /stop).", fn: stop, schema: {} },
    {
        name: "builder_api",
        desc: "Raw proxy to any builder-api endpoint (power-user escape hatch).",
        fn: builder_api,
        schema: {
            type: "object",
            properties: {
                method: { type: "string", enum: ["GET", "POST", "DELETE"], description: "HTTP method (default GET)." },
                path:   { type: "string", description: "URL path, e.g. /queue or /logs?file=build&n=20." },
                body:   { type: "object", description: "JSON body for POST." }
            }
        }
    }
];

const server = new Server(
    { name: "llm-docker-ops", version: "0.1.0" },
    { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: TOOLS.map(t => ({
        name: t.name,
        description: t.desc,
        inputSchema: t.schema && Object.keys(t.schema).length ? t.schema : { type: "object", properties: {} }
    }))
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const { name, arguments: args = {} } = req.params;
    const tool = TOOLS.find(t => t.name === name);
    if (!tool) return { content: [{ type: "text", text: `unknown tool: ${name}` }], isError: true };
    try {
        return { content: [{ type: "text", text: await tool.fn(args) }] };
    } catch (e) {
        return { content: [{ type: "text", text: `ERROR: ${e.message}\n${e.stack || ""}` }], isError: true };
    }
});

await server.connect(new StdioServerTransport());
