#!/usr/bin/env bash
# Shared by the gates that must judge a referenced SCRIPT's content, not just the command
# text (grep-memory-gate.sh; the DB write gates).
#
# Those gates read the COMMAND TEXT to decide whether a write is happening. That misses the
# most common shape in this harness: the write sits inside a script file and the command is
# just `bash scratch/foo.sh`. Not an exotic evasion -- inline-loop-gate.sh and
# multiline-string-gate.sh both push commands INTO script files, so it is the shape the
# harness recommends. Confirmed live 2026-09-11: a qa `updateOne` ran unchallenged from a
# scratch script, and the same route reaches production.
#
# Scope is deliberately narrow (user decision, 2026-09-11): only files under a repo
# `scratch/` directory or under the session scratchpad root are read. Those are where
# throwaway DB scripts actually live. A committed application script is not scanned -- this
# guards ad-hoc agent work, it is not a general static analyser, and reading arbitrary paths
# named on every Bash call is a cost nobody asked for.
#
#   scan_referenced_scripts "<command text>"   -> echoes the contents of each scannable file
#                                                 the command references (empty if none)
#
# NOTE for callers: do NOT apply heredoc scoping (`${cmd%%<<*}`) to the returned text. That
# trick strips a heredoc BODY from a command line because a commit message is data, not code
# -- but inside a script file the heredoc body IS the code (e.g. the JS eval handed to
# docdb-query.sh, which is exactly where the write lives).

# Biggest file worth reading; a throwaway DB script is never near this.
SCAN_MAX_BYTES="${SCAN_MAX_BYTES:-65536}"

# Is this path one we are willing to open?
_scan_path_allowed() {
    case "$1" in
        # Repo scratch dirs, either separator.
        */scratch/*|*\\scratch\\*) return 0 ;;
        # Session scratchpad (Claude Code temp root), either separator.
        */Temp/claude/*|*\\Temp\\claude\\*) return 0 ;;
        */temp/claude/*|*\\temp\\claude\\*) return 0 ;;
        *) return 1 ;;
    esac
}

scan_referenced_scripts() {
    local cmd="$1" tok cleaned out='' had_glob=''

    # Cheap pre-check: nothing that looks like a scannable root, do no work at all.
    case "$cmd" in
        *scratch*|*Temp/claude*|*Temp\\claude*|*temp/claude*) : ;;
        *) return 0 ;;
    esac

    # Split on whitespace WITHOUT pathname expansion -- an unquoted $cmd would otherwise
    # glob against the cwd, making what this gate sees depend on what happens to be on disk.
    case "$-" in *f*) had_glob='' ;; *) had_glob=1; set -f ;; esac

    # A file only VIEWED/moved (`nl -ba x.sh | sed -n 1,9p`, `cp x.sh y.sh`) never runs, so its
    # text is not inlined (false denies 2026-11-10, a49ed07a/cdeda3d8). Segment head = first word
    # after a separator. Conservative: any pipe INTO a non-viewer (`cat x.sql | psql`) disables it.
    local readers=' cat head tail nl less more grep rg wc diff ls stat file cp mv sed awk '
    local seg_head='' new_seg=1 view_ok=1 w after_pipe=''
    for w in $cmd; do
        case "$w" in '|') after_pipe=1; continue ;; esac
        if [ -n "$after_pipe" ]; then
            case "$readers" in *" $w "*) : ;; *) view_ok='' ;; esac
            after_pipe=''
        fi
        case "$w" in *'|'?*) view_ok='' ;; esac
    done

    for tok in $cmd; do
        case "$tok" in '|'|'||'|'&&'|';'|'&'|'('|'$(') new_seg=1; continue ;; esac
        if [ -n "$new_seg" ]; then seg_head="${tok#\$(}"; seg_head="${seg_head#(}"; new_seg=''; fi
        case "$tok" in *';'|*'&&'|*'|') new_seg=1 ;; esac
        if [ -n "$view_ok" ] && [ "$tok" != "$seg_head" ]; then
            case "$readers" in *" $seg_head "*) continue ;; esac
        fi
        # Strip surrounding quotes and trailing shell punctuation.
        cleaned="${tok%\"}"; cleaned="${cleaned#\"}"
        cleaned="${cleaned%\'}"; cleaned="${cleaned#\'}"
        cleaned="${cleaned%;}"; cleaned="${cleaned%,}"; cleaned="${cleaned%)}"

        # $HOME and ~ ARE resolvable, and must be resolved: short-path-gate.sh tells every
        # session to write scratch paths as "$HOME/..." rather than the 8.3 form, so the
        # harness's own path rule was steering commands into the one shape this scanner
        # could not read. Confirmed live 2026-09-15 -- a script running CREATE/ALTER TABLE
        # was invoked as `bash "$HOME/AppData/Local/Temp/claude/.../x.sh"` and passed both
        # DB gates untouched. Same class as the bypass this file was written for: one gate
        # recommends a shape another gate is blind to.
        case "$cleaned" in
            '$HOME'/*)   cleaned="$HOME/${cleaned#\$HOME/}" ;;
            '${HOME}'/*) cleaned="$HOME/${cleaned#\$\{HOME\}/}" ;;
            '~'/*)       cleaned="$HOME/${cleaned#\~/}" ;;
        esac

        # Anything STILL unexpanded cannot be resolved here -- skip rather than guess. The
        # caller's own "could not resolve the environment" handling covers it.
        case "$cleaned" in
            *'$'*|*'`'*|*'*'*|*'?'*) continue ;;
        esac

        _scan_path_allowed "$cleaned" || continue
        [ -f "$cleaned" ] || continue
        # The command (re)writes this file itself (`cat > s.sh <<EOF`, `tee s.sh`, `sed -i ... s.sh`):
        # the on-disk text is STALE -- the body that will run is in the command text the gates
        # already scan. Reading the old file denied a fixed heredoc rewrite (2026-10-29).
        case "$cmd" in *">"*"$tok"*|*"tee "*"$tok"*|*"sed -i"*"$tok"*|*"perl -i"*"$tok"*) continue ;; esac

        out="$out
$(head -c "$SCAN_MAX_BYTES" "$cleaned" 2>/dev/null)"
    done

    [ -n "$had_glob" ] && set +f

    printf '%s' "$out"
}
