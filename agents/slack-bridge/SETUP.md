# Slack App Setup Guide

Step-by-step guide to create the Slack App and generate the tokens needed by `slack-bridge` and `slack-notify`.

---

## 1. Create the Slack App (from manifest)

1. Go to **https://api.slack.com/apps**
2. Click **"Create New App"**
3. Choose **"From an app manifest"**
4. Select your workspace, click **Next**
5. Switch to the **YAML** tab
6. Paste the contents of [`slack-app-manifest.yaml`](slack-app-manifest.yaml)
7. Click **Next**, review, then **Create**

This configures everything automatically: bot name, scopes, event subscriptions, and Socket Mode.

---

## 2. Generate the App-Level Token

1. After creation, go to **Settings → Basic Information**
2. Scroll to **"App-Level Tokens"**
3. Click **"Generate Token and Scopes"**
   - Token Name: `socket-mode`
   - Scope: `connections:write`
   - Click **"Generate"**
4. **Copy the `xapp-...` token** — this is your `SLACK_APP_TOKEN`

---

## 3. Install to Workspace and Get Bot Token

1. Go to **Features → OAuth & Permissions**
2. Click **"Install to Workspace"**
3. Review the permissions and click **"Allow"**
4. **Copy the `xoxb-...` token** — this is your `SLACK_BOT_TOKEN`

---

## 4. Get the Channel ID

You need the channel ID (not name) for automatic notifications.

1. In Slack, right-click the channel you want notifications in
2. Click **"View channel details"**
3. At the bottom of the panel, find **Channel ID** (looks like `C0123456789`)
4. Copy it — this is your `SLACK_NOTIFY_CHANNEL`

---

## 5. Create the OpenShift Secret

```bash
oc create secret generic claude-slack-tokens \
  --from-literal=SLACK_BOT_TOKEN=xoxb-YOUR-TOKEN-HERE \
  --from-literal=SLACK_APP_TOKEN=xapp-YOUR-TOKEN-HERE \
  --from-literal=SLACK_NOTIFY_CHANNEL=C0123456789 \
  -n agent-sandboxes
```

---

## 6. Invite the Bot to a Channel

1. In Slack, go to the channel where you want to use the bot
2. Type `/invite @Claude Code Agent` (or whatever you named it)
3. The bot needs to be in the channel to receive @mentions

---

## 7. Build and Deploy

> **Note:** The Secret from step 5 must exist before the bridge Deployment starts.
> You can also use the template: `oc apply -f agents/slack-bridge/manifests/secret.yaml` (edit the placeholders first).

```bash
# Apply RBAC (ServiceAccount + Role + RoleBinding)
oc apply -f agents/slack-bridge/manifests/rbac.yaml -n agent-sandboxes

# Build slack-bridge image
oc new-build --binary --name=slack-bridge --to=slack-bridge:latest -n agent-sandboxes --strategy=docker
oc patch bc/slack-bridge -n agent-sandboxes -p '{"spec":{"resources":{"requests":{"cpu":"500m","memory":"512Mi"},"limits":{"cpu":"1","memory":"2Gi"}}}}'
oc start-build slack-bridge --from-dir=agents/slack-bridge -n agent-sandboxes --follow

# Deploy
oc apply -f agents/slack-bridge/manifests/deployment.yaml -n agent-sandboxes

# Rebuild claude-code image (for MCP server + hook updates)
oc start-build claude-code-agent --from-dir=agents/claude-code -n agent-sandboxes --follow

# Restart agent pod to pick up new image + secret
oc rollout restart deployment/claude-code-standalone -n agent-sandboxes
```

---

## 8. Test

**User → Agent (in Slack):**
```
@Claude Code Agent What is 2 + 2?
```
Expected: bot posts "Working on it..." then replies with the answer.

**Agent → Slack (from the pod):**
```bash
oc exec deploy/claude-code-standalone -c claude-code -- \
  claude -p "Send a message to Slack channel C0123456789 saying hello" \
  --dangerously-skip-permissions --output-format text
```
Expected: agent uses the `slack_send_message` MCP tool to post "hello" to the channel.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Bot doesn't respond to @mentions | Make sure the bot is invited to the channel (`/invite @BotName`) |
| `SLACK_APP_TOKEN` error | Verify it starts with `xapp-` and has `connections:write` scope |
| `SLACK_BOT_TOKEN` error | Verify it starts with `xoxb-` and has all scopes from [`slack-app-manifest.yaml`](slack-app-manifest.yaml) |
| Bridge can't find agent pod | Check label selector: `oc get pods -l app.kubernetes.io/component=agent-standalone -n agent-sandboxes` |
| Bridge can't exec into pod | Check RBAC: `oc auth can-i create pods --subresource=exec --as=system:serviceaccount:agent-sandboxes:slack-bridge -n agent-sandboxes` |
| MCP tools not available | Check `SLACK_BOT_TOKEN` is set in pod env: `oc exec deploy/claude-code-standalone -c claude-code -- env \| grep SLACK` |
| Slack notifications not firing | Check `SLACK_NOTIFY_CHANNEL` is set and `send_slack.sh` is executable |
| NetworkPolicy blocking Slack | Add egress rule for `slack.com:443` in `agent-sandboxes` namespace |
