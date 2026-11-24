# shellcheck shell=bash disable=SC2154  # sourced by setup.sh after components/common.sh (config variables)
# claude-code (optional): Claude Code for ec2-user, using Amazon Bedrock.
#
# The Region comes from instance metadata, so it always matches where the
# instance runs. Model IDs are in config/settings.env (CLAUDE_*). The instance
# role needs Bedrock invoke permissions for those models.

desc() { echo "Claude Code with Amazon Bedrock (optional)"; }
deps() { echo base; }
desired_version() { echo "latest;${CLAUDE_OPUS_MODEL}"; }

install() {
  export PATH="${HOME}/.local/bin:${PATH}"
  command -v claude >/dev/null || retry 3 10 bash -c 'curl -fsSL https://claude.ai/install.sh | bash'

  local token region
  token="$(curl -sS -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")"
  region="$(curl -sS -H "X-aws-ec2-metadata-token: ${token}" http://169.254.169.254/latest/meta-data/placement/region)"

  # settings.json: Bedrock settings, merged into an existing file.
  mkdir -p "${HOME}/.claude"
  REGION="${region}" CLAUDE_OPUS_MODEL="${CLAUDE_OPUS_MODEL}" CLAUDE_HAIKU_MODEL="${CLAUDE_HAIKU_MODEL}" \
    CLAUDE_FABLE_MODEL="${CLAUDE_FABLE_MODEL}" python3 - "${HOME}/.claude/settings.json" <<'EOF'
import json, os, sys
p = sys.argv[1]
s = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) > 0 else {}
s.setdefault("env", {}).update({
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "AWS_REGION": os.environ["REGION"],
    "ANTHROPIC_DEFAULT_OPUS_MODEL": os.environ["CLAUDE_OPUS_MODEL"],
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": os.environ["CLAUDE_HAIKU_MODEL"],
    "ANTHROPIC_DEFAULT_FABLE_MODEL": os.environ["CLAUDE_FABLE_MODEL"],
})
json.dump(s, open(p, "w"), indent=2)
EOF
  # ~/.claude.json: skip the first-run theme prompt; trust the workspace folder.
  python3 - "${HOME}/.claude.json" "${DATA_DIR}/workspace" <<'EOF'
import json, os, sys
p, ws = sys.argv[1], sys.argv[2]
d = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) > 0 else {}
d["hasCompletedOnboarding"] = True
d.setdefault("theme", "dark")
d.setdefault("projects", {}).setdefault(ws, {})["hasTrustDialogAccepted"] = True
json.dump(d, open(p, "w"), indent=2)
EOF
}

verify() {
  export PATH="${HOME}/.local/bin:${PATH}"
  command -v claude >/dev/null || die "claude not on PATH"
  grep -q '"CLAUDE_CODE_USE_BEDROCK": "1"' "${HOME}/.claude/settings.json" || die "Bedrock settings missing"
  ok "$(claude --version 2>/dev/null | head -1), Bedrock in $(python3 -c 'import json,os; print(json.load(open(os.path.expanduser("~/.claude/settings.json")))["env"]["AWS_REGION"])')"
}
