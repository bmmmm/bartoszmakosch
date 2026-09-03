# Bartosz Makosch Homepage

Welcome to the private homepage of Bartosz Makosch, a computer engineer, programmer, and cycling enthusiast.

Visit the website at: https://bartoszmakosch.com

Explore the site to learn more about Bartosz and his projects.

## How the project list stays current

The visible list, the "recently pushed" line, the two status lines on the
drawn screen, `llms.txt`, `feed.xml` and the JSON-LD block are all rendered
from one file: `projects.json` in [bmmmm/bmmmm](https://github.com/bmmmm/bmmmm),
which that repo builds daily from its curated categories plus live GitHub
metadata. This page never curates a second time, and everything is generated
in one pass by `.github/scripts/build-site.sh`, so the outputs cannot say
different things.

A daily GitHub Actions job (`.github/workflows/site.yml`) re-renders and
commits only when something changed. Cloudflare Pages deploys from `main`.

To run the render locally against a saved copy of the feed:

    FEED_URL=file:///path/to/projects.json .github/scripts/build-site.sh
