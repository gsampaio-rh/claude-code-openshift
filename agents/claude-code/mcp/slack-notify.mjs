#!/usr/bin/env node
/**
 * slack-notify — local MCP server (stdio transport) for agent-initiated Slack messaging.
 *
 * Tools:
 *   - slack_send_message(channel, text)  — post a message to a Slack channel
 *   - slack_reply_thread(channel, thread_ts, text) — reply in a specific thread
 *
 * Requires SLACK_BOT_TOKEN env var.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import https from "node:https";

const SLACK_BOT_TOKEN = process.env.SLACK_BOT_TOKEN;
if (!SLACK_BOT_TOKEN) {
  process.stderr.write("SLACK_BOT_TOKEN not set — slack-notify MCP disabled\n");
  process.exit(1);
}

function slackPost(endpoint, body) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const req = https.request(
      {
        hostname: "slack.com",
        path: `/api/${endpoint}`,
        method: "POST",
        headers: {
          Authorization: `Bearer ${SLACK_BOT_TOKEN}`,
          "Content-Type": "application/json; charset=utf-8",
          "Content-Length": Buffer.byteLength(data),
        },
        timeout: 10000,
      },
      (res) => {
        let buf = "";
        res.on("data", (c) => (buf += c));
        res.on("end", () => {
          try {
            resolve(JSON.parse(buf));
          } catch {
            reject(new Error(`Slack response not JSON: ${buf}`));
          }
        });
      }
    );
    req.on("error", reject);
    req.write(data);
    req.end();
  });
}

const server = new Server(
  { name: "slack-notify", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "slack_send_message",
      description:
        "Send a message to a Slack channel. Use this to notify users about task completion, errors, or any agent-initiated communication.",
      inputSchema: {
        type: "object",
        properties: {
          channel: {
            type: "string",
            description: "Slack channel ID (e.g. C0123456789) or channel name (e.g. #general)",
          },
          text: {
            type: "string",
            description: "Message text (supports Slack mrkdwn formatting)",
          },
        },
        required: ["channel", "text"],
      },
    },
    {
      name: "slack_reply_thread",
      description:
        "Reply to a specific thread in a Slack channel. Use this to follow up on a previous conversation.",
      inputSchema: {
        type: "object",
        properties: {
          channel: {
            type: "string",
            description: "Slack channel ID",
          },
          thread_ts: {
            type: "string",
            description: "Thread timestamp to reply to",
          },
          text: {
            type: "string",
            description: "Reply text (supports Slack mrkdwn formatting)",
          },
        },
        required: ["channel", "thread_ts", "text"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  if (name === "slack_send_message") {
    const result = await slackPost("chat.postMessage", {
      channel: args.channel,
      text: args.text,
    });
    if (!result.ok) {
      return { content: [{ type: "text", text: `Slack error: ${result.error}` }], isError: true };
    }
    return {
      content: [
        {
          type: "text",
          text: `Message sent to ${args.channel} (ts: ${result.ts})`,
        },
      ],
    };
  }

  if (name === "slack_reply_thread") {
    const result = await slackPost("chat.postMessage", {
      channel: args.channel,
      thread_ts: args.thread_ts,
      text: args.text,
    });
    if (!result.ok) {
      return { content: [{ type: "text", text: `Slack error: ${result.error}` }], isError: true };
    }
    return {
      content: [
        {
          type: "text",
          text: `Reply sent to thread ${args.thread_ts} in ${args.channel}`,
        },
      ],
    };
  }

  return { content: [{ type: "text", text: `Unknown tool: ${name}` }], isError: true };
});

const transport = new StdioServerTransport();
await server.connect(transport);
