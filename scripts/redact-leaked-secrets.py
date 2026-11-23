"""Scrub leaked credentials out of this session's transcript and scratch files (old chat logs too).

Deliberately reports only FILENAMES and COUNTS -- printing a match to prove the match would
recreate the leak it is cleaning up.

Matches by assignment context rather than by value shape where the value shape is generic:
an AWS secret key is 40 chars of [A-Za-z0-9/+], which as a bare regex would eat half a JWT
and every base64 blob in the transcript.

Rewrites in place with open(w), which truncates the existing inode -- it does NOT rename a
temp file over the target, so a symlinked path stays a symlink (the thing sed -i breaks).

Then says whether each redacted value ALSO sits in git (2026-11-10, user: the nightly ping is
noise unless a value reached somewhere published): a file whose real path is inside a work
tree is looked up at HEAD and at every refs/remotes/* tip -- `  COMMITTED  <path>` /
`  PUBLISHED <ref>  <path>`, or `  UNCHECKED  <path>` when git errors. Blobs come through
`git cat-file --batch` on stdin and the values are compared in Python, so no value reaches
argv. Untracked, ignored or uncommitted = local only, nothing printed. A value pasted into
Slack/Jira/mail is invisible here; output-secret-leak-gate.sh asks that per incident.
"""
import os
import re
import subprocess
import sys

PATTERNS = [
    # value-shaped, safe to match anywhere
    (re.compile(r"AKIA[0-9A-Z]{16}"), "[REDACTED-AWS-ACCESS-KEY-ID]"),
    (re.compile(r"API-[A-Z0-9]{20,}"), "[REDACTED-OCTOPUS-API-KEY]"),
    # signed JWT (Cognito ?jwt= in a browser URL, 2026-11-08): header AND payload both `eyJ`
    (re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"), "[REDACTED-JWT]"),
    # Slack incoming-webhook URL = post rights to the channel (Lambda env in a terraform plan, 2026-11-21)
    (re.compile(r"(hooks\.slack\.com/services/)[A-Za-z0-9]+/[A-Za-z0-9]+/[A-Za-z0-9]+"), r"\1[REDACTED-SLACK-WEBHOOK]"),
    # assignment-context, for values too generic to match on their own
    (re.compile(r"(AWS_SECRET_ACCESS_KEY\s*=\s*)([A-Za-z0-9/+=]{20,})"), r"\1[REDACTED]"),
    (re.compile(r"(APP_PASSWORD\s*=\s*)(\S{8,})"), r"\1[REDACTED]"),
    (re.compile(r"(OCTOPUS_CLI_API_KEY\s*=\s*)(\S{8,})"), r"\1[REDACTED]"),
    # any credential-named env var as printed by env/printenv/set (2026-10-08: a `env | grep
    # CLAUDE` dumped claude_*_pw test-user passwords). Value stops at whitespace, quote or the
    # backslash of a JSON-escaped \n. Placeholders skipped -- $VAR, <x>, [REDACTED], `...`,
    # null/none/true/false: the first cut rewrote `PGPASSWORD=...` and `claude_ui_test_pw=null`
    # in tracked docs/gates (reverted).
    # 2026-10-28: also quoted values (`export X="v"`, `\"` once JSONL-escaped) and
    # API_KEY/_PAT/PASSPHRASE names -- a Read of ~/.bashrc slipped past all of this.
    (re.compile(r"(?:(?<![A-Za-z0-9_])|(?<=\\[nrt]))([A-Za-z_][A-Za-z0-9_]*?(?:_pw|_PW|_pass|_PASS|PASSWORD|password|Password|SECRET|secret|TOKEN|token|API_KEY|api_key|APIKEY|_PAT|PASSPHRASE|passphrase)=(?:\\?[\"'])?)(?![$<\[%{(`.*])(?!(?:null|none|None|true|false)(?![^\s\"'\\`]))([^\s\"'\\`]{4,})"), r"\1[REDACTED]"),
    # JSON forms, in case a value was captured as a field rather than a printed line
    (re.compile(r'("(?:AWS_SECRET_ACCESS_KEY|APP_PASSWORD|OCTOPUS_CLI_API_KEY)"\s*:\s*")[^"]+'), r"\1[REDACTED]"),
    (re.compile(r'("(?:Proposed)?Password"\s*:\s*")[^"]+'), r"\1[REDACTED]"),
]

# By VALUE: every credential-named env var's own value, wherever it appears (bare, quoted,
# inside a URL) -- read from the environment, never argv, so the value is never typed. Run
# from a shell that sourced ~/.bashrc. 12+ chars only (short values hit unrelated text).
ENV_NAME = re.compile(r"(?:_pw|_PW|_pass|_PASS|PASSWORD|SECRET|TOKEN|API_KEY|APIKEY|_PAT|PASSPHRASE)$", re.I)
for _name, _val in sorted(os.environ.items()):
    if ENV_NAME.search(_name) and len(_val) >= 12 and not _val.startswith(("$", "<", "[")):
        PATTERNS.append((re.compile(re.escape(_val)), f"[REDACTED-{_name}]"))

SKIP_DIRS = {".git", "node_modules", "obj", "bin", ".vs", "dist"}
SKIP_SELF = os.path.abspath(__file__)


def scrub(path, found):
    """Redact in place; returns the hit count and adds each original matched text to found."""
    try:
        with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
            original = fh.read()
    except (OSError, UnicodeDecodeError):
        return 0

    # Count only matches the rewrite CHANGES: several patterns (APP_PASSWORD=\S{8,}, the JSON
    # forms) also match their own "[REDACTED]" output, and counting those re-reported every
    # already-scrubbed file nightly as a fresh RISK (2026-11-10: ~100 of ~140 hits were no-ops).
    text = original
    hits = 0
    for rx, repl in PATTERNS:
        def sub(m, repl=repl):
            nonlocal hits
            new = m.expand(repl)
            if new != m.group(0):
                hits += 1
                found.add(m.group(0))
            return new
        text = rx.sub(sub, text)

    if hits and text != original:
        with open(path, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
            fh.write(text)
    return hits


def walk(root):
    if os.path.isfile(root):
        yield root
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            yield os.path.join(dirpath, name)


def repo_root(real):
    d = os.path.dirname(real)
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def cat_blobs(top, specs):
    """{"<ref>:<path>": text or None} via `git cat-file --batch` -- specs on stdin, never argv."""
    data = "".join(s + "\n" for s in specs).encode("utf-8", "surrogateescape")
    out = subprocess.run(["git", "-C", top, "cat-file", "--batch"], input=data,
                         capture_output=True, timeout=120, check=True).stdout
    res, i = {}, 0
    for s in specs:
        nl = out.index(b"\n", i)
        line, i = out[i:nl], nl + 1
        if line.endswith((b" missing", b" ambiguous")):
            res[s] = None
            continue
        _sha, typ, size = line.split(b" ")
        body, i = out[i:i + int(size)], i + int(size) + 1
        res[s] = body.decode("utf-8", "surrogateescape") if typ == b"blob" else None
    return res


def in_git(changed):
    """[(verdict, path)] for each redacted file whose value is also in git. Values are the
    original matched texts; AWS's documented example key (...EXAMPLE: gate fixtures and the
    public-mirror clones in scratch) is not a credential."""
    by_top = {}
    for path, found in changed:
        real = os.path.realpath(path)
        top = repo_root(real)
        vals = [v for v in found if "EXAMPLE" not in v]
        if top and vals:
            by_top.setdefault(top, []).append((path, os.path.relpath(real, top).replace(os.sep, "/"), vals))
    verdicts = []
    for top, items in by_top.items():
        try:
            heads = cat_blobs(top, [f"HEAD:{rel}" for _, rel, _ in items])
            held = lambda text, vals: text is not None and any(v in text for v in vals)
            committed = [(p, rel, vals) for p, rel, vals in items if held(heads[f"HEAD:{rel}"], vals)]
            if not committed:
                continue
            refs = subprocess.run(["git", "-C", top, "for-each-ref", "--format=%(refname)", "refs/remotes"],
                                  stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60, check=True).stdout.split()
            for p, rel, vals in committed:
                blobs = cat_blobs(top, [f"{r}:{rel}" for r in refs]) if refs else {}
                pushed = next((r for r in refs if held(blobs[f"{r}:{rel}"], vals)), None)
                verdicts.append((f"PUBLISHED {pushed[len('refs/remotes/'):]}" if pushed else "COMMITTED", p))
        except (OSError, ValueError, subprocess.SubprocessError):
            verdicts.extend(("UNCHECKED", p) for p, _, _ in items)
    return verdicts


def main(roots):
    total_files = 0
    total_hits = 0
    changed = []
    for root in roots:
        if not os.path.exists(root):
            print(f"  (absent) {root}")
            continue
        for path in walk(root):
            if os.path.abspath(path) == SKIP_SELF:
                continue
            try:
                if os.path.getsize(path) > 200 * 1024 * 1024:
                    continue
            except OSError:
                # dangling symlink (chat logs are symlinks; some targets are gone)
                continue
            found = set()
            n = scrub(path, found)
            if n:
                total_files += 1
                total_hits += n
                changed.append((path, found))
                print(f"  {n:>4} redaction(s)  {path}")
    verdicts = in_git(changed)
    for verdict, path in verdicts:
        print(f"  {verdict}  {path}")
    print(f"\nfiles changed: {total_files}   redactions: {total_hits}")
    count = lambda k: sum(1 for v, _ in verdicts if v.startswith(k))
    print(f"in git: pushed {count('PUBLISHED')}   committed {count('COMMITTED')}   unchecked {count('UNCHECKED')}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
