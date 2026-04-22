#!/bin/bash
# Hook script — reads event JSON from stdin, wraps in envelope, POSTs to agents-observe server.
# Uses a temp file to safely pass arbitrary JSON to node without escaping issues.

SERVER_URL="${AGENTS_OBSERVE_API_BASE_URL:-http://agents-observe.agent-sandboxes.svc:4981/api}/events"
PROJECT_SLUG="${AGENTS_OBSERVE_PROJECT_SLUG:-claude-openshift}"

tmpfile=$(mktemp)
cat > "$tmpfile"

node -e '
const fs = require("fs");
const http = require("http");
const raw = fs.readFileSync(process.argv[1], "utf8");
fs.unlinkSync(process.argv[1]);
const payload = JSON.parse(raw);
const envelope = {
  hook_payload: payload,
  meta: { env: { AGENTS_OBSERVE_PROJECT_SLUG: process.argv[2] } }
};
const data = JSON.stringify(envelope);
const url = new URL(process.argv[3]);
const req = http.request({
  hostname: url.hostname,
  port: url.port,
  path: url.pathname,
  method: "POST",
  headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data) },
  timeout: 3000,
}, () => { process.exit(0); });
req.on("error", () => { process.exit(0); });
req.write(data);
req.end();
' "$tmpfile" "$PROJECT_SLUG" "$SERVER_URL" > /dev/null 2>&1
