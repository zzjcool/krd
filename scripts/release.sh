#!/usr/bin/env bash
#
# scripts/release.sh -- cut a krd release.
#
#   ./scripts/release.sh 0.2.0 --dry-run   # validate + show the plan, change nothing
#   ./scripts/release.sh 0.2.0             # ask, then commit / tag / push
#   ./scripts/release.sh 0.2.0 --yes       # unattended (no tty, e.g. CI)
#
# The script refuses to run on a dirty worktree or on a tag that already
# exists (locally or on the remote), keeps VERSION and Sources/krd/Version.swift
# in sync, then commits, tags and pushes the branch plus the tag to origin.

set -euo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '\n==> %s\n' "$*"
}

usage() {
  cat <<'USAGE'
usage: scripts/release.sh <version> [--dry-run] [--yes]

Cut a krd release: sync VERSION and Sources/krd/Version.swift, commit
"chore(release): v<version>", tag v<version> and push branch plus tag to origin.

  <version>   bare semantic version, e.g. 0.2.0 (the tag carries the v prefix)

  --dry-run   validate everything and print the plan, change nothing
  --yes, -y   skip the confirmation prompt (required when stdin is not a tty)
  -h, --help  show this help

Refuses to run when the worktree is dirty, when no branch is checked out, when
the version is not X.Y.Z[-pre][+build], or when tag v<version> already exists.
USAGE
}

# Single source of truth for the two version files, so VERSION, Version.swift
# and the tag can never drift apart.
write_version_files() {
  printf '%s\n' "$1" > VERSION
  {
    printf '%s\n' "// Version of the krd executable, printed by \`krd --version\`."
    printf '%s\n' '//'
    printf '%s\n' '// This file and the repository VERSION file are kept in sync by'
    printf '%s\n' '// scripts/release.sh, which rewrites both and then tags the commit'
    printf '%s\n' '// (run ./scripts/release.sh X.Y.Z). Do not bump them by hand unless'
    printf '%s\n' '// you update both, or the binary and the tag will drift apart.'
    printf 'let krdVersion = "%s"\n' "$1"
  } > Sources/krd/Version.swift
}

# --- arguments -------------------------------------------------------------

dry_run=0
assume_yes=0
version=''

while [ "$#" -gt 0 ]; do
  case $1 in
    --dry-run) dry_run=1 ;;
    -y | --yes) assume_yes=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      die "unknown option: $1"
      ;;
    *)
      [ -z "$version" ] || die "unexpected extra argument: $1"
      version=$1
      ;;
  esac
  shift
done

if [ -z "$version" ]; then
  usage >&2
  die 'missing version argument'
fi

if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'; then
  die "version '$version' is not a bare semantic version like 0.2.0"
fi

tag="v${version}"

# --- preflight -------------------------------------------------------------

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || die 'not inside a git repository'
cd "$repo_root"

[ -f VERSION ] || die "VERSION not found in $repo_root"
[ -f Sources/krd/Version.swift ] || die "Sources/krd/Version.swift not found in $repo_root"

branch=$(git symbolic-ref -q --short HEAD) || die 'detached HEAD: check out a branch before releasing'

dirty=$(git status --porcelain)
if [ -n "$dirty" ]; then
  printf 'error: git worktree is not clean, commit or stash first:\n%s\n' "$dirty" >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
  die "tag ${tag} already exists locally"
fi

remote=origin
have_remote=1
if ! git remote get-url "$remote" >/dev/null 2>&1; then
  have_remote=0
  [ "$dry_run" -eq 1 ] || die "git remote '$remote' is not configured; add it with: git remote add origin <url>"
fi

if [ "$have_remote" -eq 1 ] &&
  git ls-remote --exit-code --tags "$remote" "refs/tags/${tag}" >/dev/null 2>&1; then
  die "tag ${tag} already exists on $remote"
fi

# --- plan ------------------------------------------------------------------

remote_note=''
[ "$have_remote" -eq 1 ] || remote_note=' (missing: a real run would abort here)'

step 'release plan'
printf 'repository   %s\n' "$repo_root"
printf 'branch       %s\n' "$branch"
printf 'remote       %s%s\n' "$remote" "$remote_note"
printf 'version      %s -> %s\n' "$(cat VERSION)" "$version"
printf 'tag          %s (annotated)\n' "$tag"
printf 'files        VERSION, Sources/krd/Version.swift\n'
printf 'steps\n'
printf '  1. write "%s" into VERSION and Sources/krd/Version.swift\n' "$version"
printf '  2. git commit -m "chore(release): %s"\n' "$tag"
printf '  3. git tag -a %s -m "krd %s"\n' "$tag" "$tag"
printf '  4. git push %s HEAD:refs/heads/%s\n' "$remote" "$branch"
printf '  5. git push %s refs/tags/%s\n' "$remote" "$tag"

if [ "$dry_run" -eq 1 ]; then
  step 'dry run'
  printf 'nothing was written, committed, tagged or pushed.\n'
  exit 0
fi

# --- confirmation ----------------------------------------------------------

if [ "$assume_yes" -ne 1 ]; then
  [ -t 0 ] || die 'confirmation needs a tty; re-run with --yes to skip the prompt'
  printf '\nCommit, tag and push %s to %s? Type "yes" to continue: ' "$tag" "$remote"
  answer=''
  read -r answer || answer=''
  case $answer in
    y | Y | yes | YES | Yes) ;;
    *) die 'aborted: nothing was changed' ;;
  esac
fi

# --- do it -----------------------------------------------------------------

step "synchronising version $version"
write_version_files "$version"
git --no-pager diff --stat -- VERSION Sources/krd/Version.swift
git add VERSION Sources/krd/Version.swift
git commit -m "chore(release): ${tag}"

step "tagging $tag"
git tag -a "$tag" -m "krd ${tag}"

step "pushing $branch and $tag to $remote"
printf 'if a push fails, the local commit and tag stay in place: fix the remote\n'
printf 'and retry with: git push %s HEAD:refs/heads/%s && git push %s refs/tags/%s\n' \
  "$remote" "$branch" "$remote" "$tag"
git push "$remote" "HEAD:refs/heads/${branch}"
git push "$remote" "refs/tags/${tag}"

step 'done'
printf 'krd %s released: %s is on %s (%s)\n' "$version" "$tag" "$remote" "$branch"
printf 'the tag push runs .github/workflows/release.yml.\n'
