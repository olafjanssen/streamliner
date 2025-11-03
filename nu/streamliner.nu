# Streamliner (pure Nushell)
#
# Dependencies:
# - Nushell >= 0.90
# - gh (GitHub CLI) authenticated for GitHub URLs
# - glab (GitLab CLI) authenticated for GitLab URLs
#
# Usage:
#   streamliner github <url>
#   streamliner gitlab <url>
#   streamliner rss <url>
#   streamliner http <url>
#
# Returns a record: { items: [ {url title content needs_further_processing source timestamp} ... ] }

# Backward-compat shim: `streamliner get <url>` will try to auto-detect
export def main [sub: string, url?: string] {
    match $sub {
        'github' => { streamliner github $url },
        'gitlab' => { streamliner gitlab $url },
        'rss' => { streamliner rss $url },
        'http' => { streamliner http $url },
        'get' => { streamliner autodetect $url },
        _ => { error make { msg: ("unknown subcommand: " + $sub) } }
    }
}

# Explicit subcommands
export def "streamliner github" [url: string] {
    if ($url | is-empty) { error make { msg: "usage: streamliner github <url>" } }
    let parsed = ($url | url parse)
    { items: (sl github-items $parsed) }
}

export def "streamliner gitlab" [url: string] {
    if ($url | is-empty) { error make { msg: "usage: streamliner gitlab <url>" } }
    let parsed = ($url | url parse)
    { items: (sl gitlab-items $parsed) }
}

export def "streamliner rss" [url: string] {
    if ($url | is-empty) { error make { msg: "usage: streamliner rss <url>" } }
    { items: (sl rss-or-atom-items $url) }
}

export def "streamliner http" [url: string] {
    if ($url | is-empty) { error make { msg: "usage: streamliner http <url>" } }
    { items: (sl http-items $url) }
}

# Backward compat: autodetect route
export def "streamliner autodetect" [url: string] {
    if ($url | is-empty) { error make { msg: "usage: streamliner get <url>" } }
    let parsed = ($url | url parse)
    let host = ($parsed.host? | default "")
    if ($host | str ends-with "github.com") { return (streamliner github $url) }
    if ($host | str ends-with "gitlab.com") { return (streamliner gitlab $url) }
    if (($parsed.scheme? == 'http' or $parsed.scheme? == 'https' or $parsed.scheme? == 'feed') and (
        ($parsed.path? | default '' | str ends-with ".xml") or
        ($parsed.path? | default '' | str ends-with ".rss") or
        ($url | str downcase | str contains "feed")
    )) { return (streamliner rss $url) }
    (streamliner http $url)
}

# ---------- Providers ----------

def sl [command: string, ...rest] { null }

# GitHub: expects https://github.com/OWNER/REPO[/*]
export def "sl github-items" [parsed: record] {
    let segs = ($parsed.path? | default '' | split row '/' | where {|s| $s != ''})
    if ($segs | length) < 2 { return [] }
    let owner = ($segs | get 0)
    let repo  = ($segs | get 1)

    # Issues (exclude PRs)
    let issues = (^{gh} api $"/repos/($owner)/($repo)/issues" --paginate | from json
        | where {|it| ($it | get pull_request? | is-empty)}
        | each {|it|
            { 
                url: ($it.html_url),
                title: ($it.title),
                content: ($it.body? | default ""),
                needs_further_processing: false,
                source: "github:issue",
                timestamp: ($it.created_at | into datetime | default null)
            }
        }
    )

    # Releases
    let releases = (^{gh} api $"/repos/($owner)/($repo)/releases" --paginate | from json
        | each {|it|
            { 
                url: ($it.html_url),
                title: ($it.name? | default "Release"),
                content: ($it.body? | default ""),
                needs_further_processing: false,
                source: "github:release",
                timestamp: ($it.published_at? | into datetime | default null)
            }
        }
    )

    $issues | append $releases
}

# GitLab: expects https://gitlab.com/NAMESPACE/PROJECT[/*]
export def "sl gitlab-items" [parsed: record] {
    let project_path = ($parsed.path? | default '' | str trim -c '/' )
    if ($project_path | is-empty) { return [] }
    let project_enc = (url encode $project_path)

    let issues = (^{glab} api $"/projects/($project_enc)/issues" | from json
        | each {|it|
            { 
                url: ($it.web_url),
                title: ($it.title),
                content: ($it.description? | default ""),
                needs_further_processing: false,
                source: "gitlab:issue",
                timestamp: ($it.created_at | into datetime | default null)
            }
        }
    )

    let mrs = (^{glab} api $"/projects/($project_enc)/merge_requests" | from json
        | each {|it|
            { 
                url: ($it.web_url),
                title: ($it.title),
                content: ($it.description? | default ""),
                needs_further_processing: false,
                source: "gitlab:mr",
                timestamp: ($it.created_at | into datetime | default null)
            }
        }
    )

    $issues | append $mrs
}

# RSS/Atom via http + from xml
export def "sl rss-or-atom-items" [url: string] {
    let raw = (http get $url)
    let xml = ($raw.body | from xml)

    # Try RSS first: rss.channel.item
    let rss_items = ($xml.rss.channel.item? | default [])
    if ($rss_items | is-not-empty) {
        return ($rss_items | each {|it|
            let title = ($it.title? | default "")
            let summary = ($it.description? | default "")
            {
                url: ($it.link? | default ""),
                title: $title,
                content: (if ($summary | is-empty) { $title } else { $"($title)\n\n($summary)" }),
                needs_further_processing: true,
                source: "rss",
                timestamp: ($it.pubDate? | into datetime | default null)
            }
        })
    }

    # Atom: feed.entry
    let atom_items = ($xml.feed.entry? | default [])
    if ($atom_items | is-not-empty) {
        return ($atom_items | each {|it|
            let title = ($it.title? | default "")
            let link = (do {
                let l = ($it.link? | default {})
                if ($l.@href? | is-empty) { $l | to text } else { $l.@href }
            })
            let summary = ($it.summary? | default ($it.content? | default ""))
            {
                url: ($link | default ""),
                title: $title,
                content: (if ($summary | is-empty) { $title } else { $"($title)\n\n($summary)" }),
                needs_further_processing: true,
                source: "atom",
                timestamp: ($it.updated? | into datetime | default null)
            }
        })
    }

    []
}

# HTTP: fetch a single web page and return as one item
export def "sl http-items" [url: string] {
    let resp = (http get $url)
    let body = ($resp.body | into string)
    let title = (do {
        let m = ($body | parse --regex '(?is)<title>(.*?)</title>' | get capture0? | get 0? | default "")
        if ($m | is-empty) { $url } else { $m | str trim }
    })
    [
        {
            url: $url,
            title: $title,
            content: $body,
            needs_further_processing: false,
            source: "http",
            timestamp: (date now)
        }
    ]
}
