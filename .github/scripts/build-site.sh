#!/usr/bin/env bash
# build-site.sh — render everything on this site that comes from the profile
# feed: the visible project list, the "recently pushed" line, two lines on the
# drawn ASCII screen, llms.txt, feed.xml and the JSON-LD block.
#
# Source of truth is projects.json in the bmmmm/bmmmm repo, built there from
# the curated categories plus live GitHub metadata. This page never curates a
# second time: a project appears here because it appears there.
#
# All outputs are rendered from the same feed in one pass, on purpose.
# Metadata that claims more than the page shows a human is cloaking, and
# generating everything together is what keeps the outputs from drifting
# into it.
#
# URLs into this site are written relative, never absolute, and the domain is
# never spelled out in this mirrored repo. Where a format needs an absolute
# IRI (the Atom feed) the GitHub URLs from the feed serve as identifiers.
set -euo pipefail

FEED_URL="${FEED_URL:-https://raw.githubusercontent.com/bmmmm/bmmmm/main/projects.json}"
# Permanent id of the Atom feed. Minted once; changing it makes every reader
# treat the feed as a new one.
FEED_UUID="bf88393a-ff9d-4e7f-abd8-b1a238cdc96f"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
index="$root/index.html"
llms="$root/llms.txt"
atom="$root/feed.xml"

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

# Every project, newest push first, regardless of category. Used by the
# "recently pushed" line, the screen and the feed.
jq '[.categories[].projects[]] | sort_by(.pushed_at // .updated // "") | reverse' "$feed" > "$tmp/by-push.json"

# ── visible list ────────────────────────────────────────────────────────────
# One <li> per project with the date of its last push. A date is the cheapest
# proof that a list is alive; without one, thirty entries read as a monument.
jq -r '
  .categories[] |
  "                <h3>" + .title + "</h3>",
  "                <p class=\"tagline\">" + .tagline + "</p>",
  "                <ul>",
  ( .projects[] |
    "                    <li><a href=\"" + .url + "\">" + .name + "</a> — " + .blurb
    + (if .live then " <a href=\"" + .live + "\">live</a>" else "" end)
    + (if .updated then " <time class=\"when\" datetime=\"" + .updated + "\">" + .updated + "</time>" else "" end)
    + "</li>" ),
  "                </ul>"
' "$feed" > "$tmp/list.html"

# ── recently pushed ─────────────────────────────────────────────────────────
jq -r '
  .[:5] |
  "                <p class=\"recent\">Recently pushed: "
  + ( map("<a href=\"" + .url + "\">" + .name + "</a> <time class=\"when\" datetime=\"" + (.updated // "") + "\">" + (.updated // "") + "</time>") | join(", ") )
  + ".</p>"
' "$tmp/by-push.json" > "$tmp/recent.html"

# ── the drawn screen ────────────────────────────────────────────────────────
# Two lines of the ASCII terminal are generated: the sites line and the
# last-push line. The screen is 48 columns wide between its borders, three of
# them indent; a line that renders one character too long breaks the drawing.
# So every generated line is measured with its markup stripped, and the build
# fails rather than ship a broken laptop. Generated text stays ASCII: the
# measurement counts bytes, and the runner's locale is not a thing to depend on.
screen_line() {  # <html> → the full <pre> line, padded out to the right border
  local html="$1" visible len
  visible="$(printf '%s' "$html" | sed -E 's/<[^>]*>//g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g')"
  len=${#visible}
  if [ "$len" -gt 45 ]; then
    echo "build-site: screen line is $len columns, max 45: $visible" >&2; exit 1
  fi
  printf '          ||   %s%*s||' "$html" $((45 - len)) ''
}

sites_html="$(jq -r '
  (.sites // []) | map("<a href=\"" + .url + "\" target=\"_blank\" rel=\"noopener\">" + .name + "</a>") | join("  ")
' "$feed")"
[ -n "$sites_html" ] && sites_html="Sites@: $sites_html"
sites_line="$(screen_line "$sites_html")"

IFS=$'\t' read -r lp_name lp_url lp_date < <(jq -r '.[0] | [.name, .url, (.updated // "")] | @tsv' "$tmp/by-push.json")
lastpush_line="$(screen_line "\$ last push: <a href=\"$lp_url\">$lp_name</a> $lp_date <span class=\"cursor\">_</span>")"

# ── JSON-LD ─────────────────────────────────────────────────────────────────
# Person and WebSite only. Google has no rich result for SoftwareSourceCode,
# and a knowsAbout list built from repo topics was tried: 188 terms, among
# them "car" and "bonn", making up half the page. The five category titles
# say what the page is about; the projects say the rest in visible text.
jq -n --slurpfile f "$feed" --arg name "$site_name" '
  {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "Person",
        "@id": "#person",
        "name": $name,
        "url": "/",
        "description": "Builds LLM and agent tooling, local-first web apps and small command-line tools, with an emphasis on measuring and verifying what software claims to do.",
        "knowsAbout": [$f[0].categories[].title],
        "sameAs": ["https://github.com/bmmmm"]
      },
      {
        "@type": "WebSite",
        "@id": "#website",
        "url": "/",
        "author": { "@id": "#person" }
      }
    ]
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
  echo "source, with the date of each project's last push. Source code for all of"
  echo "them: https://github.com/bmmmm"
  echo
  jq -r '
    .categories[] |
    "## " + .title, "",
    .tagline + ".", "",
    ( .projects[] |
      "- [" + .name + "](" + .url + "): " + .blurb
      + (if .live then " Live: " + .live else "" end)
      + " (" + ([.language, (if .updated then "last push " + .updated else null end)] | map(select(. != null)) | join(", ")) + ")" ),
    ""
  ' "$feed"
  echo "## Contact"
  echo
  echo "- [Privacy policy and disclaimer](disclaimer.html)"
  echo "- [PGP key](pgp.html)"
  echo "- [Atom feed of recent pushes](feed.xml)"
} > "$llms"

# ── feed.xml ────────────────────────────────────────────────────────────────
# One entry per project. The entry id carries the date of the last push, so a
# project that is pushed to again shows up in a reader again — the feed is an
# activity stream, not a catalogue. Given name only, same reason as llms.txt.
#
# Atom wants absolute IRIs for ids. The entries use their GitHub URLs; the
# feed itself uses a fixed urn:uuid, minted once for this feed, so that no
# line here has to spell out the site's own domain.
feed_id="urn:uuid:$FEED_UUID"
jq -r --arg owner "$(jq -r '.owner // "bmmmm"' "$feed")" --arg id "$feed_id" --arg name "$given_name" '
  def esc: @html;
  def when: .pushed_at // ((.updated // "1970-01-01") + "T00:00:00Z");
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
  "<feed xmlns=\"http://www.w3.org/2005/Atom\">",
  "  <title>" + ($name | esc) + ": recently pushed projects</title>",
  "  <subtitle>One entry per project, renewed whenever it is pushed to. Source for all of them: https://github.com/" + $owner + "</subtitle>",
  "  <link href=\"https://github.com/" + $owner + "\"/>",
  "  <id>" + $id + "</id>",
  "  <updated>" + (.[0] | when) + "</updated>",
  "  <author><name>" + ($name | esc) + "</name></author>",
  ( .[] |
    "  <entry>",
    "    <title>" + ((.name + " — " + .blurb) | esc) + "</title>",
    "    <link href=\"" + (.url | esc) + "\"/>",
    "    <id>" + (.url | esc) + "#" + (.updated // "") + "</id>",
    "    <updated>" + when + "</updated>",
    "    <summary>" + (.blurb | esc) + "</summary>",
    "    <content type=\"text\">" + ((.detail // .blurb) | esc) + "</content>",
    "  </entry>" ),
  "</feed>"
' "$tmp/by-push.json" > "$atom"

# ── sitemap.xml ─────────────────────────────────────────────────────────────
# Three pages do not need a sitemap for a crawler to FIND them — the front page
# links both others. It exists for lastmod: this page is rebuilt whenever a
# project is pushed to, and without a date a crawler has no way to learn that
# except by fetching it again.
#
# So only "/" carries a lastmod, and it is the real one — the newest push in
# the feed. The other two get none: the runner checks out shallow, so their
# commit dates are not available here, and a lastmod that is guessed is worse
# than none. Crawlers learn to distrust the field, and then it is worth nothing
# on the page where it was true.
#
# The absolute URL the protocol requires is read out of the committed canonical
# link, so the domain still never appears in this script.
site_url="$(sed -n 's|.*<link rel="canonical" href="\([^"]*\)".*|\1|p' "$index" | head -1)"
[ -n "$site_url" ] || { echo "build-site: no canonical link in index.html to take the site URL from" >&2; exit 1; }
site_url="${site_url%/}"

{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
  printf '  <url><loc>%s/</loc><lastmod>%s</lastmod></url>\n' "$site_url" "$lp_date"
  printf '  <url><loc>%s/disclaimer</loc></url>\n' "$site_url"
  printf '  <url><loc>%s/pgp</loc></url>\n' "$site_url"
  echo '</urlset>'
} > "$root/sitemap.xml"

# ── splice into index.html ──────────────────────────────────────────────────
# Block markers stand on their own lines and enclose whole lines. Inline
# markers sit on one line inside the <pre>, where an extra line would render
# as a blank row on the screen.
for marker in jsonld recent projects; do
  grep -q "<!-- $marker:start -->" "$index" || {
    echo "build-site: no $marker:start marker in index.html" >&2; exit 1; }
  grep -q "<!-- $marker:end -->" "$index" || {
    echo "build-site: no $marker:end marker in index.html" >&2; exit 1; }
done
for marker in sites lastpush; do
  grep -q "<!-- $marker:start -->.*<!-- $marker:end -->" "$index" || {
    echo "build-site: no inline $marker markers in index.html" >&2; exit 1; }
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

splice_inline() {  # <marker> <html> — replaces what stands between the markers on their line
  awk -v marker="$1" -v html="$2" '
    BEGIN { s = "<!-- " marker ":start -->"; e = "<!-- " marker ":end -->" }
    index($0, s) && index($0, e) {
      i = index($0, s); j = index($0, e)
      $0 = substr($0, 1, i - 1) s html e substr($0, j + length(e))
    }
    { print }
  ' "$index" > "$tmp/index.html"
  mv "$tmp/index.html" "$index"
}

splice jsonld "$tmp/ld.html"
splice recent "$tmp/recent.html"
splice projects "$tmp/list.html"
splice_inline sites "$sites_line"
splice_inline lastpush "$lastpush_line"

echo "build-site: $count projects, last push $lp_name $lp_date"
