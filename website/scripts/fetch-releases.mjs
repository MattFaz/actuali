// Fetches GitHub releases for the changelog page and writes them to
// src/data/github-releases.json before `astro build` runs.
//
// This must run in plain Node (not in the page frontmatter): Astro's
// Cloudflare adapter prerenders pages inside an emulated Workers runtime
// where build-shell env vars like GITHUB_TOKEN are invisible and thrown
// errors are caught and rendered as a 500 page while the build still exits
// 0. Here the token is readable and a failure aborts the whole build.
//
// Authenticate when a token is available. Cloudflare's build runners share
// egress IPs, so the unauthenticated GitHub limit (60 req/hr/IP) is often
// already exhausted and the fetch 403s. A token raises the limit to 5,000
// req/hr. Set GITHUB_TOKEN as a build secret in Cloudflare (Workers &
// Pages > Settings > Build > Variables and secrets).

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = "MattFaz/actuali";
const OUT_FILE = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "src",
  "data",
  "github-releases.json"
);

const githubToken = process.env.GITHUB_TOKEN;
const headers = {
  Accept: "application/vnd.github+json",
  "User-Agent": "actuali-website",
};
if (githubToken) headers.Authorization = `Bearer ${githubToken}`;

const res = await fetch(
  `https://api.github.com/repos/${REPO}/releases?per_page=100`,
  { headers }
);
if (!res.ok) {
  const hint =
    res.status === 403 && !githubToken
      ? " (unauthenticated rate limit — set the GITHUB_TOKEN build secret)"
      : res.status === 401
        ? " (GITHUB_TOKEN is set but GitHub rejected it — expired, revoked, or mispasted; generate a fine-grained PAT with public-repo read access and update the Cloudflare build secret)"
        : "";
  console.error(`Changelog: GitHub releases fetch failed (${res.status})${hint}`);
  process.exit(1);
}

const data = await res.json();
const releases = data
  .filter((r) => !r.draft && !r.prerelease)
  .map((r) => ({
    tag_name: r.tag_name,
    published_at: r.published_at,
    body: r.body,
  }));

if (releases.length === 0) {
  console.error("Changelog: GitHub returned no published releases — refusing to build an empty changelog.");
  process.exit(1);
}

await mkdir(dirname(OUT_FILE), { recursive: true });
await writeFile(OUT_FILE, JSON.stringify(releases, null, 2) + "\n");
console.log(`Changelog: wrote ${releases.length} releases to src/data/github-releases.json`);
