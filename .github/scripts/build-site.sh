#!/usr/bin/env bash
# build-site.sh — render the visible project list, llms.txt and the JSON-LD
# block from the profile feed.
#
# Source of truth is projects.json in the bmmmm/bmmmm repo, built there from
# the curated categories plus live GitHub metadata. This page never curates a
# second time: a project appears here because it appears there.
#
# The visible list, llms.txt and knowsAbout are rendered from the same feed in
# one pass, on purpose. Metadata that claims more than the page shows a human
# is cloaking, and the point of generating all three together is that they
# cannot drift into it.
#
# URLs into this site are written relative, never absolute. JSON-LD resolves a
# relative IRI against the document base, so the output is correct either way,
# and the domain then never has to be spelled out in a mirrored repo.
set -euo pipefail

FEED_URL="${FEED_URL:-https://raw.githubusercontent.com/bmmmm/bmmmm/main/projects.json}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
index="$root/index.html"
llms="$root/llms.txt"

command -v jq >/dev/null || { echo "build-site: jq is required" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
feed="$tmp/projects.json"

curl -fsSL --max-time 30 "$FEED_URL" -o "$feed"
jq -e '.categories | length > 0' "$feed" >/dev/null \
  || { echo "build-site: feed has no categories — refusing to publish an empty page" >&2; exit 1; }

count="$(jq -r '[.categories[].projects[]] | length' "$feed")"
[ "$count" -ge 10 ] || { echo "build-site: only $count projects in the feed — refusing, this looks like a broken build upstream" >&2; exit 1; }

# The full name is read out of the committed <title>, never written into this
# script. The surname is a guarded value: keeping it out of the source means a
# later edit here can never re-introduce it into a diff. It reaches exactly one
# generated line, the Person node, and stays unchanged context from then on.
# Everything else uses the given name alone.
site_name="$(sed -n 's|.*<title>\(.*\)</title>.*|\1|p' "$index" | head -1)"
[ -n "$site_name" ] || { echo "build-site: no <title> in index.html to take the name from" >&2; exit 1; }
given_name="${site_name%% *}"

# ── knowsAbout ──────────────────────────────────────────────────────────────
# Every topic set on the listed repos, plus their languages, normalised and
# deduped. No frequency threshold: it was tried and it selects for the wrong
# thing here. Requiring a term on 3+ repos drops anthropic, claude-code, llm
# and ai-agents — the strongest and most specific signals, each concentrated
# in one or two projects — while four FreshRSS extensions push their shared
# tags to the top. Frequency measures repetition, not competence.
#
# Every term is therefore already vouched for: it is a tag someone put on a
# real repository. Normalisation only merges spellings of one thing, so that
# the list does not read as machine-dumped (Go and golang, self-hosted and
# selfhosted).
jq -r '
  def canon: ascii_downcase
    | if . == "golang" then "go"
      elif . == "vanilla-js" then "javascript"
      elif . == "selfhosted" then "self-hosted"
      else . end;
  ([.categories[].projects[].topics[]?] + [.categories[].projects[].language // empty])
  | map(canon) | unique | .[]
' "$feed" > "$tmp/knows.txt"

# ── visible list ────────────────────────────────────────────────────────────
jq -r '
  .categories[] |
  "                <h3>" + .title + "</h3>",
  "                <p class=\"tagline\">" + .tagline + "</p>",
  "                <ul>",
  ( .projects[] |
    "                    <li><a href=\"" + .url + "\">" + .name + "</a> — " + .blurb
    + (if .live then " <a href=\"" + .live + "\">live</a>" else "" end) + "</li>" ),
  "                </ul>"
' "$feed" > "$tmp/list.html"

# ── JSON-LD ─────────────────────────────────────────────────────────────────
jq -n --slurpfile f "$feed" --rawfile knows "$tmp/knows.txt" --arg name "$site_name" '
  ($f[0]) as $feed |
  {
    "@context": "https://schema.org",
    "@graph": ([
      {
        "@type": "Person",
        "@id": "#person",
        "name": $name,
        "url": "/",
        "description": "Builds LLM and agent tooling, local-first web apps and small command-line tools, with an emphasis on measuring and verifying what software claims to do.",
        "knowsAbout": ($knows | rtrimstr("\n") | split("\n")),
        "sameAs": ["https://github.com/bmmmm"]
      },
      {
        "@type": "WebSite",
        "@id": "#website",
        "url": "/",
        "author": { "@id": "#person" }
      }
    ] + [
      $feed.categories[].projects[] | {
        "@type": "SoftwareSourceCode",
        "name": .name,
        "codeRepository": .url,
        "description": .blurb,
        "programmingLanguage": .language,
        "author": { "@id": "#person" }
      } | with_entries(select(.value != null))
    ])
  }' > "$tmp/ld.json"

{
  echo '        <script type="application/ld+json">'
  jq --indent 2 . "$tmp/ld.json" | sed 's/^/        /'
  echo '        </script>'
} > "$tmp/ld.html"

# ── llms.txt ────────────────────────────────────────────────────────────────
{
  # Given name only. This file exists to be ingested wholesale, which makes it
  # the wrong place for a value that is deliberately kept out of datasets; the
  # identity link an agent needs is the sameAs in the JSON-LD.
  echo "# $given_name"
  echo
  echo "> Builds LLM and agent tooling, local-first web apps and small command-line"
  echo "> tools. Recurring theme: a claim is not a result — the tools measure and"
  echo "> verify rather than assert."
  echo
  echo "This file lists the same projects the page shows, generated from the same"
  echo "source. Source code for all of them: https://github.com/bmmmm"
  echo
  jq -r '
    .categories[] |
    "## " + .title, "",
    .tagline + ".", "",
    ( .projects[] |
      "- [" + .name + "](" + .url + "): " + .blurb
      + (if .live then " Live: " + .live else "" end)
      + (if .language then " (" + .language + ")" else "" end) ),
    ""
  ' "$feed"
  echo "## Contact"
  echo
  echo "- [Legal notice and privacy policy](disclaimer.html)"
  echo "- [PGP key](pgp.html)"
} > "$llms"

# ── splice both blocks into index.html ──────────────────────────────────────
for marker in jsonld projects; do
  grep -q "<!-- $marker:start -->" "$index" || {
    echo "build-site: no $marker:start marker in index.html" >&2; exit 1; }
  grep -q "<!-- $marker:end -->" "$index" || {
    echo "build-site: no $marker:end marker in index.html" >&2; exit 1; }
done

splice() {  # <marker> <content-file>
  awk -v marker="$1" -v content="$2" '
    $0 ~ "<!-- " marker ":start -->" {
      print
      while ((getline line < content) > 0) print line
      skip = 1; next
    }
    $0 ~ "<!-- " marker ":end -->" { skip = 0 }
    !skip
  ' "$index" > "$tmp/index.html"
  mv "$tmp/index.html" "$index"
}

splice jsonld "$tmp/ld.html"
splice projects "$tmp/list.html"

echo "build-site: $count projects, $(wc -l < "$tmp/knows.txt" | tr -d ' ') knowsAbout terms"
