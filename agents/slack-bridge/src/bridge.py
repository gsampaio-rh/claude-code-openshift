"""
Slack Bridge — bidirectional adapter between Slack and Claude Code agent.

Receives Slack messages via Socket Mode, invokes `claude -p` in the
claude-code-standalone pod via Kubernetes exec, and posts responses back.

Session mapping (hybrid):
  - Messages in a Slack thread share a Claude Code session (--resume)
  - Messages directly in a channel are one-shot (no --resume)
"""

import asyncio
import json
import logging
import os
import re
import sys

from slack_bolt.app.async_app import AsyncApp
from slack_bolt.adapter.socket_mode.async_handler import AsyncSocketModeHandler
from slack_sdk.web.async_client import AsyncWebClient
from kubernetes_asyncio import client, config
from kubernetes_asyncio.stream import WsApiClient

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("slack-bridge")

SLACK_BOT_TOKEN = os.environ["SLACK_BOT_TOKEN"]
SLACK_APP_TOKEN = os.environ["SLACK_APP_TOKEN"]

AGENT_POD_LABEL = os.getenv("AGENT_POD_LABEL", "app.kubernetes.io/component=agent-standalone")
AGENT_NAMESPACE = os.getenv("AGENT_NAMESPACE", "agent-sandboxes")
AGENT_CONTAINER = os.getenv("AGENT_CONTAINER", "claude-code")
MAX_CONCURRENT = int(os.getenv("MAX_CONCURRENT_EXECS", "2"))
MAX_TURNS = os.getenv("CLAUDE_MAX_TURNS", "30")

ALLOWED_CHANNELS = set(filter(None, os.getenv("SLACK_ALLOWED_CHANNELS", "").split(",")))
ALLOWED_USERS = set(filter(None, os.getenv("SLACK_ALLOWED_USERS", "").split(",")))

SLACK_MSG_LIMIT = 3900

app = AsyncApp(token=SLACK_BOT_TOKEN)
exec_semaphore = asyncio.Semaphore(MAX_CONCURRENT)

# thread_ts -> session_id
session_map: dict[str, str] = {}


def truncate_for_slack(text: str) -> str:
    if len(text) <= SLACK_MSG_LIMIT:
        return text
    return text[:SLACK_MSG_LIMIT] + "\n\n_(truncated)_"


def is_allowed(channel_id: str, user_id: str) -> bool:
    if ALLOWED_CHANNELS and channel_id not in ALLOWED_CHANNELS:
        return False
    if ALLOWED_USERS and user_id not in ALLOWED_USERS:
        return False
    return True


async def find_agent_pod() -> str:
    v1 = client.CoreV1Api()
    label_key, label_val = AGENT_POD_LABEL.split("=", 1)
    pods = await v1.list_namespaced_pod(
        namespace=AGENT_NAMESPACE,
        label_selector=f"{label_key}={label_val}",
        field_selector="status.phase=Running",
    )
    if not pods.items:
        raise RuntimeError(f"No running pod with label {AGENT_POD_LABEL} in {AGENT_NAMESPACE}")
    return pods.items[0].metadata.name


async def exec_claude(prompt: str, session_id: str | None = None) -> tuple[str, str | None]:
    """Run claude -p in the agent pod. Returns (output_text, session_id)."""
    cmd = [
        "claude", "-p",
        "--output-format", "text",
        "--max-turns", MAX_TURNS,
        "--dangerously-skip-permissions",
    ]
    if session_id:
        cmd.extend(["--resume", session_id])
    cmd.append(prompt)

    pod_name = await find_agent_pod()
    log.info("Exec into pod %s: %s", pod_name, prompt[:80])

    async with WsApiClient() as ws_api:
        v1 = client.CoreV1Api(api_client=ws_api)
        stdout_data = await v1.connect_get_namespaced_pod_exec(
            name=pod_name,
            namespace=AGENT_NAMESPACE,
            container=AGENT_CONTAINER,
            command=["bash", "-c", " ".join(f"'{c}'" if " " in c else c for c in cmd)],
            stderr=True,
            stdin=False,
            stdout=True,
            tty=False,
        )

    if not isinstance(stdout_data, str):
        stdout_data = str(stdout_data)

    result_text = stdout_data.strip() if stdout_data else "(no response from agent)"

    # Filter out the stdin warning that Claude CLI emits in non-interactive mode
    lines = [l for l in result_text.split("\n")
             if not l.startswith("Warning: no stdin data")]
    result_text = "\n".join(lines).strip() or "(no response from agent)"

    return result_text, session_id


@app.event("app_mention")
async def handle_mention(event, say):
    channel = event["channel"]
    user = event["user"]
    text = re.sub(r"<@\w+>\s*", "", event.get("text", "")).strip()
    thread_ts = event.get("thread_ts") or event.get("ts")

    if not is_allowed(channel, user):
        await say(text="This channel/user is not authorized.", thread_ts=thread_ts)
        return

    if not text:
        await say(text="Send me a message after the mention.", thread_ts=thread_ts)
        return

    await say(text=":hourglass_flowing_sand: Working on it...", thread_ts=thread_ts)

    session_id = session_map.get(thread_ts) if event.get("thread_ts") else None

    try:
        async with exec_semaphore:
            response, new_session_id = await exec_claude(text, session_id)

        if event.get("thread_ts") and new_session_id:
            session_map[thread_ts] = new_session_id

        await say(text=truncate_for_slack(response), thread_ts=thread_ts)
    except Exception as e:
        log.exception("Error executing claude -p")
        await say(text=f":x: Error: {e}", thread_ts=thread_ts)


@app.event("message")
async def handle_dm(event, say):
    if event.get("channel_type") != "im":
        return
    if event.get("subtype"):
        return

    channel = event["channel"]
    user = event["user"]
    text = event.get("text", "").strip()
    thread_ts = event.get("thread_ts") or event.get("ts")

    if not is_allowed(channel, user):
        return

    if not text:
        return

    await say(text=":hourglass_flowing_sand: Working on it...", thread_ts=thread_ts)

    session_id = session_map.get(thread_ts) if event.get("thread_ts") else None

    try:
        async with exec_semaphore:
            response, new_session_id = await exec_claude(text, session_id)

        if event.get("thread_ts") and new_session_id:
            session_map[thread_ts] = new_session_id

        await say(text=truncate_for_slack(response), thread_ts=thread_ts)
    except Exception as e:
        log.exception("Error executing claude -p")
        await say(text=f":x: Error: {e}", thread_ts=thread_ts)


async def main():
    try:
        config.load_incluster_config()
    except config.ConfigException:
        await config.load_kube_config()

    log.info("Starting slack-bridge (Socket Mode)...")
    log.info("  Namespace:  %s", AGENT_NAMESPACE)
    log.info("  Pod label:  %s", AGENT_POD_LABEL)
    log.info("  Container:  %s", AGENT_CONTAINER)
    log.info("  Max concurrent: %s", MAX_CONCURRENT)

    handler = AsyncSocketModeHandler(app, SLACK_APP_TOKEN)
    await handler.start_async()


if __name__ == "__main__":
    asyncio.run(main())
