#!/usr/bin/env bash
set -euo pipefail

# Render the site using every CPU core.
#
# A plain "quarto render" converts every post serially in one process, and
# naive per-file parallel renders ("quarto render posts/x.markdown" via
# xargs -P) race on shared staging files (site_libs/, search.json,
# sitemap.xml) and litter the project with stray output. Instead:
#
#   1. split the posts round-robin across one lightweight clone of the
#      project per CPU core,
#   2. render each clone with a single quarto process, all in parallel,
#   3. copy the rendered posts back and merge the per-clone search indexes,
#   4. render index.qmd for real (its listing + RSS feed need every post),
#   5. rebuild the sitemap from the final contents of docs/.

cd "$(dirname "$0")"

SITE_URL="https://superlab.ca"
CORES=$(getconf _NPROCESSORS_ONLN)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

posts=(posts/*.markdown)
N=$CORES
(( N > ${#posts[@]} )) && N=${#posts[@]}

# 1. One clone per core. index.qmd is deliberately left out of the clones:
#    its listing and feed need all posts, so it renders last, in step 4.
for ((i = 0; i < N; i++)); do
  mkdir -p "$WORK/clone$i/posts"
  cp _quarto.yml about.qmd subscribe.qmd join.qmd *.scss *.css *.png "$WORK/clone$i/"
done
i=0
for p in "${posts[@]}"; do
  cp "$p" "$WORK/clone$((i % N))/posts/"
  i=$((i + 1))
done

# 2. Render all clones in parallel, one quarto process each.
echo "render.sh: rendering ${#posts[@]} posts across $N parallel quarto processes..."
pids=()
for ((i = 0; i < N; i++)); do
  ( cd "$WORK/clone$i" && quarto render --quiet ) &
  pids+=($!)
done
fail=0
for pid in "${pids[@]}"; do
  wait "$pid" || fail=1
done
if (( fail )); then
  echo "render.sh: one or more render chunks failed" >&2
  exit 1
fi

# 3. Collect the rendered pieces. site_libs and the top-level pages are
#    identical in every clone, so clone0's copies are taken as-is.
mkdir -p docs/posts
for ((i = 0; i < N; i++)); do
  cp "$WORK/clone$i/docs/posts/"*.html docs/posts/
done
rm -rf docs/site_libs
cp -R "$WORK/clone0/docs/site_libs" docs/site_libs
cp "$WORK/clone0/docs/about.html" \
   "$WORK/clone0/docs/subscribe.html" \
   "$WORK/clone0/docs/join.html" docs/

# Merge the per-clone search indexes. The top-level pages appear in every
# clone and are deduped; index.qmd's own entries are added by step 4, which
# updates docs/search.json in place.
jq -s '[.[][]] | unique_by(.objectID)' "$WORK"/clone*/docs/search.json > docs/search.json

# 4. Render the home page: listing table, RSS feed, search entries.
echo "render.sh: rendering index.qmd..."
quarto render index.qmd --quiet

# 5. Rebuild the sitemap from what is actually in docs/.
{
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
  find docs -name '*.html' -not -path 'docs/site_libs/*' | sort | while read -r f; do
    lastmod=$(date -u -r "$(stat -f %m "$f")" '+%Y-%m-%dT%H:%M:%SZ')
    printf '  <url>\n    <loc>%s/%s</loc>\n    <lastmod>%s</lastmod>\n  </url>\n' \
      "$SITE_URL" "${f#docs/}" "$lastmod"
  done
  printf '</urlset>\n'
} > docs/sitemap.xml

echo "render.sh: done"
