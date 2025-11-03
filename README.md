### Streamliner (Nushell)

Turn various feeds (RSS/Atom, GitHub, GitLab, HTTP) into content-rich updates using Nushell plus `gh`/`glab`.

#### Requirements
- Nushell >= 0.90
- GitHub CLI `gh` (authenticated) for GitHub URLs
- GitLab CLI `glab` (authenticated) for GitLab URLs

#### Load
```nu
source /Users/olafjanssen/Repos/cli/streamliner/nu/streamliner.nu
```

#### Usage (explicit subcommands)
```nu
# GitHub repository (issues + releases)
streamliner github https://github.com/OWNER/REPO

# GitLab project (issues + merge requests)
streamliner gitlab https://gitlab.com/NAMESPACE/PROJECT

# RSS/Atom feed
streamliner rss https://example.com/feed.xml

# Generic HTTP page (single item of page content)
streamliner http https://example.com/page
```

Optional backward-compat: `streamliner get <url>` will try to auto-detect provider and route accordingly.

Each command returns a record:
- `items`: list of items with fields `url`, `title`, `content`, `needs_further_processing`, `source`, `timestamp`

Example to work with items:
```nu
(streamliner rss https://example.com/feed.xml).items | select timestamp title url
```
