# AGENTS.md — working on the mutineer gem

Conventions for any agent or contributor changing this repo. (Usage docs for
*consumers* live in `README.md` and `docs/`; this file is about developing the gem.)

## Non-negotiables

- **Zero runtime dependencies — Prism + stdlib only.** Never add a runtime gem.
  Dev-only deps (minitest, rake, yard) are fine. Ruby **≥ 3.4** (Prism ships with it).
- **No `eval`.** Removed in 0.6.1 (supply-chain scanner flag). The redefine strategy
  `load`s a tempfile snippet instead — don't reintroduce `eval`.
- **Least astonishment.** Names match behaviour, no hidden side effects, explicit
  failures over silent ones. Match the surrounding code's idiom.

## Before every commit (local gate)

```sh
bundle exec rake test                          # zero-dep suite
ruby -Ilib -e 'require "mutineer"'             # load smoke
bundle exec rake yard:strict                    # 100% documented — see below
```

The default `Gemfile` pins Minitest 5. For changes to the Minitest
integration, also run the suite on Minitest 6:

```sh
BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle exec rake test
```

- **`yard:strict` requires 100% documentation, including private methods AND
  constants.** Every new method and constant needs a YARD docstring / `#` comment
  or CI fails.
- **Rails-dependent tests run via `bundle exec rake test:daemon`**, never the
  zero-dep default. The gem's own suite stays Rails-free; `test/fixtures/rails_app`
  has its OWN bundle. `rake test:daemon` runs in the rails-integration CI job.
- Subprocesses use plain `bundle exec` — never hardcode `rbenv exec` (breaks CI and
  non-rbenv users).

## Website checks

For changes to the GitHub Pages site or its tests, also run:

```sh
bundle exec rake site:build
node --test test/site_test.js
npm ci --prefix test/browser
npx --prefix test/browser playwright install chromium
npm test --prefix test/browser
```

`rake site:build` writes the published tree to `_site/` — the YARD API docs,
`sitemap.xml`, `llms-full.txt`, and `json-schema.html` are build artifacts, not
committed files under `docs/`. The checks above read `_site/`, so build first.

These development-only checks require Node.js 22+, npm, and Python 3.
Playwright starts a local server on port 8766; keep that port free so the
checks run against this checkout. The gem and its default Rake suite remain
independent of Node and Playwright. CI runs these checks in `website browser tests`.

## CI gates that block merge

`yard:strict` · `test` (×2 OS) · `test (minitest 6)` · `rails dogfood` + daemon integration · `website browser tests` · socket/gitguardian.

## PR review gate (before any merge)

Applies to every open pull request, including a stack. Do not merge until
the current head meets this bar.

### Before opening a new pull request

Run the checks in "Before every commit". For a site change, run the website
checks too. Open the pull request when those checks pass.

After a later commit, run the checks that the new lines affect.

### After the pull request is open

1. Read every review comment. Fix a real finding, or write why the comment
   is wrong.
2. Reply on every thread before resolving it. A fix reply names the commit.
   A decline reply gives the reason.
3. GitHub checks are green on the head commit.
4. A person merges.

**Stacked pull requests:** start at the bottom of the stack. After a lower
pull request changes, update the ones above it and review the new lines.

## Releasing (tag-driven — CI publishes, no manual `gem push`)

**Fork release:** `justinallenmarsh/mutineer-mongoid` builds and tests each
stable tag, attaches the gem and checksum to a GitHub release, then calls
`rubygems.yml` to publish that exact artifact through Trusted Publishing.
The publisher uses the GitHub `release` environment. To publish an existing
GitHub release (including the first RubyGems release), dispatch `rubygems.yml`
on `main` with its stable tag. Existing RubyGems versions are accepted only
when their SHA-256 matches the GitHub artifact.

Semver: **new feature → minor bump, fix → patch.** A behavior change to the
GitHub Action's defaults is a **major** bump: consumers pin `@v<major>`, and a
default flip must never reach them without opting in.

1. On a branch, bump `lib/mutineer/version.rb` and move the `CHANGELOG.md`
   `## [Unreleased]` block into a dated `## [X.Y.Z] - YYYY-MM-DD` section.
2. Merge to `main`.
3. Tag and push — this is the whole release trigger:
   ```sh
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```
4. `.github/workflows/release.yml` guards `tag == Mutineer::VERSION`, runs tests,
   cuts the GitHub release from CHANGELOG, and moves the floating major tag
   (`v1`, `v2`, …). Its `rubygems` job then calls `rubygems.yml` to publish the
   verified release artifact through **Trusted Publishing** (OIDC, no API key).

Safety nets:
- The tag must equal `Mutineer::VERSION` or the release aborts.
- RubyGems publication verifies the release artifact's checksum, name, and version.
- An already published version is accepted only when its checksum matches.
- `release-pr.yml` is upstream-only and disabled in this fork. Cut release tags
  manually after the version change and required checks are on `main`.

**One-time setup (required for the publish to work):** register a Trusted Publisher
for `mutineer-mongoid` → owner `justinallenmarsh`, repo `mutineer-mongoid`,
workflow `rubygems.yml`, environment `release`. For a new gem, register a pending
trusted publisher under your RubyGems profile. No API key is stored in GitHub.

## Score-model discipline (don't regress this)

`score = killed / (killed + survived)`. `no_coverage`, `uncapturable`, `unplaceable`, `ran_at_load`, `ignored`,
`skipped`, `errored` are ALL excluded from the denominator. Empty denominator → `nil`,
never `0.0`. The exact-survivor integration oracle must stay green.
