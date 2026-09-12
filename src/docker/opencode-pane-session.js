// pane-session.js — records the session THIS opencode instance is working in.
// The host launcher (ocd) reads pane-<container>.session at exit and binds it
// to the terminal pane — so mid-run session switches are always captured.
// Mirrors only exist inside llm-docker containers; elsewhere this no-ops.
import fs from "node:fs"

const MIRROR = "/mnt/opencode-mirror"
const key = process.env.CONTAINER_NAME || "unknown"
let last = ""

export const PaneSessionPlugin = async () => ({
  event: async ({ event }) => {
    try {
      const e = event
      let sid =
        e?.properties?.info?.sessionID ??
        e?.info?.sessionID ??
        e?.properties?.sessionID ??
        e?.sessionID ??
        e?.properties?.id
      if (!sid || typeof sid !== "string" || !sid.startsWith("ses_")) {
        const m = JSON.stringify(event).match(/"ses_[A-Za-z0-9]{10,}"/)
        sid = m ? m[0].slice(1, -1) : sid
      }
      if (!sid || sid === last) return
      if (!fs.existsSync(MIRROR)) return
      last = sid
      fs.writeFileSync(`${MIRROR}/pane-${key}.session`, sid)
    } catch {
      // never break the app on bookkeeping
    }
  },
})
