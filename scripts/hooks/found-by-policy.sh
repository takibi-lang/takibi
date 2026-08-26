#!/usr/bin/env bash
# Shared policy check for the `Found-by:` provenance field.
#
# The field records HOW a defect was discovered. That fact is only available
# while the work is happening: the defect itself, its symptom, and its fix can
# all be reconstructed later from the issue tracker and from git history, but
# "the type checker rejected it" versus "three hours on a board with SWD" is
# written down at the time or lost. See AGENTS.md, "Record How a Defect Was
# Found", for why this is enforced rather than left to convention.
#
# Modes:
#   --command <command-string>        inspect an agent's shell command
#   --commit-message-file <path>      inspect a prepared commit message
#
# Exit codes:
#   0:  allowed, or outside this policy's scope
#   10: a required `Found-by:` field is missing or names an unknown value
set -euo pipefail

VALUES='type-error|compiler-lint|runtime-check|test|qemu|hardware|review|design'
FOUND_BY_RE="Found-by:[ \t]*($VALUES)(?![\w-])"
CLOSES_RE='(?i)(^|[\s(])(fix|fixes|fixed|close|closes|closed|resolve|resolves|resolved)\s+#[0-9]+'

vocabulary_help() {
  cat <<'HELP'
Use exactly one of these values:

  type-error     the Takibi compiler's type checker rejected it
  compiler-lint  a compiler lint or a scripts/check_*.py build check flagged it
  runtime-check  a compiler-emitted runtime check or kernel assertion fired
  test           a dune, QEMU-lane, or hardware test failed
  qemu           found while debugging under QEMU (gdb, boot logs)
  hardware       found on a real board (bring-up, bisect, SWD)
  review         found by reading code, by an audit, or reported by the maintainer
  design         not a defect at all: a design, research, or refactoring task

Free text may follow the value, and is the right place for what the discovery
cost:

  Found-by: hardware -- RPi5 SWD register read after a two-hour boot-log bisect
  Found-by: type-error
  Found-by: design
HELP
}

has_found_by() {
  printf '%s' "$1" | LC_ALL=C grep -qP "$FOUND_BY_RE"
}

# Distinguishes "no field at all" from "field present, value not in the
# vocabulary", so the message the author reads names the actual problem.
missing_or_unknown() {
  if printf '%s' "$1" | LC_ALL=C grep -qP 'Found-by:'; then
    printf '%s' 'has a `Found-by:` field whose value is not one of the recognized ones'
  else
    printf '%s' 'has no `Found-by:` field'
  fi
}

mode="${1:-}"
case "$mode" in
  --command)
    cmd="${2:-}"

    if printf '%s' "$cmd" | grep -Eq '(^|[;&|]|[[:space:]])gh[[:space:]]+issue[[:space:]]+create([[:space:]]|$)'; then
      if ! has_found_by "$cmd"; then
        {
          printf 'This `gh issue create` %s. Every issue records how it was discovered, including issues that are not defects.\n\n' "$(missing_or_unknown "$cmd")"
          vocabulary_help
        }
        exit 10
      fi
    fi

    if printf '%s' "$cmd" | grep -Eq '(^|[;&|]|[[:space:]])git[[:space:]]+commit([[:space:]]|$)'; then
      if printf '%s' "$cmd" | LC_ALL=C grep -qP "$CLOSES_RE" && ! has_found_by "$cmd"; then
        {
          printf 'This commit closes a GitHub issue and %s. Add a `Found-by:` trailer line to the commit message body.\n\n' "$(missing_or_unknown "$cmd")"
          vocabulary_help
        }
        exit 10
      fi
    fi
    ;;

  --commit-message-file)
    path="${2:-}"
    [ -f "$path" ] || exit 0
    # Drop the comment block git appends; it quotes the diff and the branch name.
    message="$(grep -v '^#' "$path" || true)"

    if printf '%s' "$message" | LC_ALL=C grep -qP "$CLOSES_RE"; then
      if ! printf '%s' "$message" | LC_ALL=C grep -qP "^$FOUND_BY_RE"; then
        {
          printf '%s\n\n' 'This commit message closes a GitHub issue but carries no valid `Found-by:` trailer. The trailer must be a line of its own in the message body.'
          vocabulary_help
        }
        exit 10
      fi
    fi
    ;;

  *)
    exit 0
    ;;
esac

exit 0
