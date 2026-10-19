#!/usr/bin/env bash
# Resolve the commit range for a release-notes run.
#
# Inputs (env):
#   REVISIONS  optional, e.g. "15,16" or "rev15,rev16". The highest one titles
#              the document.
#              Defaults to the highest rev<N> tag.
#   FROM_REF   optional start ref (exclusive). Defaults to the newest
#              documented revision in DOCS_DIR, then to the newest ancestor
#              rev<N> tag on a different commit than the end of the range.
#   DOCS_DIR   optional, defaults to docs/reference/release-notes.
#
# Writes key=value pairs to $GITHUB_OUTPUT (stdout when unset).
set -euo pipefail

DOCS_DIR="${DOCS_DIR:-docs/reference/release-notes}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

die() {
    echo "::error::$*" >&2
    exit 1
}

# Peel annotated tags down to the commit they point at.
peel() {
    git rev-parse --verify --quiet "$1^{commit}"
}

# Revision numbers of all flat rev<N> tags, ascending numerically.
rev_numbers() {
    git tag --list 'rev*' | grep -E '^rev[0-9]+$' | sed 's/^rev//' | sort -n
}

if [[ -n "${REVISIONS:-}" ]]; then
    revs=$(tr -s ', ' '\n' <<<"$REVISIONS" | sed '/^$/d; s/^rev//')
    if grep -qvE '^[0-9]+$' <<<"$revs"; then
        die "Invalid revisions '$REVISIONS': expected comma-separated numbers or rev<N> tags"
    fi
    for rev in $revs; do
        peel "rev$rev" >/dev/null || die "Tag rev$rev not found"
    done
    revision=$(sort -n <<<"$revs" | tail -1)
else
    revision=$(rev_numbers | tail -1)
    [[ -n "$revision" ]] || die "No rev<N> tags found"
fi

to_ref="rev$revision"
to_sha=$(peel "$to_ref") || die "Tag $to_ref not found"

if [[ -n "${FROM_REF:-}" ]]; then
    from_ref="$FROM_REF"
    from_source="input"
else
    documented=$(find "$DOCS_DIR" -maxdepth 1 -name 'revision-*.md' 2>/dev/null \
        | grep -oE 'revision-[0-9]+\.md$' | grep -oE '[0-9]+' | sort -n | tail -1 || true)
    if [[ -n "$documented" ]]; then
        if ((documented >= revision)); then
            die "Revision $documented is already documented in $DOCS_DIR (requested $revision)"
        fi
        from_ref="rev$documented"
        from_source="docs"
    else
        from_ref=""
        for n in $(rev_numbers | sort -rn); do
            ((n < revision)) || continue
            sha=$(peel "rev$n")
            if [[ "$sha" != "$to_sha" ]] && git merge-base --is-ancestor "$sha" "$to_sha"; then
                from_ref="rev$n"
                break
            fi
        done
        [[ -n "$from_ref" ]] || die "No earlier rev<N> tag found before $to_ref"
        from_source="tags"
    fi
fi

from_sha=$(peel "$from_ref") || die "Ref $from_ref not found"
git merge-base --is-ancestor "$from_sha" "$to_sha" \
    || die "$from_ref is not an ancestor of $to_ref"

commit_count=$(git rev-list --count "$from_sha..$to_sha")
((commit_count > 0)) \
    || die "Empty range $from_ref..$to_ref: both resolve to ${to_sha:0:7}"

output_path="$DOCS_DIR/revision-$revision.md"
[[ ! -e "$output_path" ]] || die "$output_path already exists"

branch="docs/release-notes-revision-$revision"
if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    die "Branch $branch already exists on origin"
fi

{
    echo "revision=$revision"
    echo "title=Revision $revision"
    echo "to_ref=$to_ref"
    echo "to_sha=$to_sha"
    echo "from_ref=$from_ref"
    echo "from_sha=$from_sha"
    echo "from_source=$from_source"
    echo "commit_count=$commit_count"
    echo "output_path=$output_path"
    echo "branch=$branch"
} >>"$OUT"
