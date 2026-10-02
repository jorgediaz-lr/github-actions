#!/bin/bash

BASE="$1"

TITLE_FILE="$2"

if [ -z "$BASE" ]; then
    echo "Usage: $0 <base-ref> [title-file]" >&2
    exit 1
fi

export TZ=UTC

COMMIT_FORMAT='%h - %ae - %s'

COMPANY_THREAD_LOCAL_PATTERNS=(
    'set'
    'lock'
    'forEach'
)

BRIAN_EMAIL='brian.chan@liferay.com'

JIRA_PROJECTS='LCD LPD LPS LRCI LRDOCS LRQA'

JIRA_URL='https://liferay.atlassian.net/browse/'

PULL_REQUEST_REPOSITORY='brianchandotcom/liferay-portal'

REGEN_SUBJECT='(^| )regen( |$)'

RELEASE_SUBJECTS='artifact:ignore|prep next|packageinfo| apply$|^bump '

TEAM_MEMBERS='IstvanD javalosjr96 jorgediaz-lr luisortiz89 marianoalvarosaiz'

TEAM_REPOSITORY='liferay-database-infra/liferay-portal'

WORK_DIR=$(mktemp -d)

trap 'rm -rf "$WORK_DIR"' EXIT

FOLDER_SECTIONS="$WORK_DIR/folder_sections.md"

LISTED_COMMITS="$WORK_DIR/listed_commits.txt"

THREAD_LOCAL_SECTIONS="$WORK_DIR/thread_local_sections.md"

section() {
    echo "#### $1"
    echo "$2"
    echo ""
}

grep '@liferay-database-infra' .github/CODEOWNERS | awk '{print $1}' | while read -r folder; do
    commits=$(git log "$BASE..HEAD" --pretty=format:"$COMMIT_FORMAT" -- "$folder")
    if [ -n "$commits" ]; then
        section "Changes in $folder" "$commits"
    fi
done >> "$FOLDER_SECTIONS"

scan_diff() {
    local method="$1"
    local mode="$2"
    git log "$BASE..HEAD" -p --pretty="format:@@COMMIT@@ $COMMIT_FORMAT" \
        | LC_ALL=C awk -v method="$method" -v mode="$mode" '
            BEGIN {
                if (mode == "add") { hre="^\\+\\+\\+ "; bre="^\\+" }
                else               { hre="^--- ";       bre="^-"   }
            }
            /^@@COMMIT@@ / { header=substr($0, 12); shown=0; skip=0; pending=0; next }
            $0 ~ hre {
                file=$2
                sub(/^[ab]\//, "", file)
                skip=(tolower(file) ~ /test/)
                pending=0
                next
            }
            $0 ~ bre {
                if (skip || shown) { pending=0; next }
                line=substr($0, 2)
                inline="CompanyThreadLocal[.][[:space:]]*" method
                if (line ~ inline) { print header; shown=1; next }
                if (pending && line ~ ("^[[:space:]]*" method)) { print header; shown=1; next }
                pending=(line ~ /CompanyThreadLocal[.][[:space:]]*$/)
                next
            }
            { pending=0 }
        '
}

for pattern in "${COMPANY_THREAD_LOCAL_PATTERNS[@]}"; do
    added=$(scan_diff "$pattern" add)
    removed=$(scan_diff "$pattern" del)
    if [ -n "$added" ]; then
        section "Added 'CompanyThreadLocal.$pattern'" "$added"
    fi
    if [ -n "$removed" ]; then
        section "Removed 'CompanyThreadLocal.$pattern'" "$removed"
    fi
done >> "$THREAD_LOCAL_SECTIONS"

# Brian cherry-picks pull requests, so master commits never keep the SHA of
# the pull request commits. A commit belongs to the pull request whose "Merged"
# comment links a compare range containing it, or else to the pull request
# with a commit of the same author email, author date and subject. Brian
# sometimes closes the pull request before pushing, so a pull request closed up
# to an hour before the commit date still counts. Every pull request closed in
# the last 7 days is a candidate, and so is any pull request of the last 60
# days whose title names the ticket number of a listed commit, whatever its
# prefix, since titles like "Lpd 82616" or "LDP-61504" happen. Commits with no
# pull request are split by author: Brian's release commits never have one, and
# his other commits, a "Regen" of a ticket included, get the closed pull request
# of the same ticket as a guess. Links go through redirect.github.com, so the
# referenced pull requests do not get a back-link to the issue.

PULL_REQUEST_FILTERS='
    def origin: (.body // "") | capture("Forwarded from: https://github.com/(?<repository>[^/]+/[^/]+)/pull/(?<number>[0-9]+)") | "\(.repository)#\(.number)";
    def tickets: if $keys == "" then "" else [.title | scan("\\b[a-z][a-z0-9]*[- ](" + $keys + ")\\b"; "i")[0]] | unique | join(" ") end;
    def row: [.number, (.closed_at // ""), (origin // ""), .title, .user.login, tickets] | @tsv;
'

find_pull_requests() {
    local commits_file="$WORK_DIR/commits.tsv"
    local pull_commits_file="$WORK_DIR/pull_commits.tsv"
    local pulls_file="$WORK_DIR/pulls.tsv"
    local ranges_file="$WORK_DIR/ranges.tsv"

    touch "$pull_commits_file" "$pulls_file" "$ranges_file"

    xargs -r git show -s --date=format-local:%Y-%m-%dT%H:%M:%SZ --pretty=tformat:'%h%x09%H%x09%ae%x09%ad%x09%ct%x09%s' < "$LISTED_COMMITS" \
        | while IFS=$'\t' read -r short sha email author_date commit_time subject; do
            printf '%s\t%s\t%s\t%s\t%(%Y-%m-%dT%H:%M:%SZ)T\t%s\t%s\n' "$short" "$sha" "$email" "$author_date" $((commit_time - 3600)) "$subject" $((commit_time - 3600))
        done > "$commits_file"

    local keys
    keys=$(cut -f6 "$commits_file" | grep -oE '\b[A-Z][A-Z0-9]+-[0-9]+\b' | sed 's/.*-//' | sort -u | paste -sd '|' -)

    local oldest_time
    oldest_time=$(cut -f7 "$commits_file" | sort -n | head -n 1)

    local newest_time
    newest_time=$(cut -f7 "$commits_file" | sort -n | tail -n 1)

    local since_time=$((newest_time - 7 * 86400))

    local keyed_since_time=$((newest_time - 60 * 86400))

    if [ -z "$keys" ]; then
        keyed_since_time=$since_time
    fi

    local since
    printf -v since '%(%Y-%m-%dT%H:%M:%SZ)T' $((since_time > oldest_time ? since_time : oldest_time))

    local keyed_since
    printf -v keyed_since '%(%Y-%m-%dT%H:%M:%SZ)T' $((keyed_since_time > oldest_time ? keyed_since_time : oldest_time))

    local page=1
    while :; do
        local page_file="$WORK_DIR/page.json"
        gh api "repos/$PULL_REQUEST_REPOSITORY/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=$page" > "$page_file" || break
        jq -r --arg keyed_since "$keyed_since" --arg keys "$keys" --arg since "$since" "$PULL_REQUEST_FILTERS"' .[] | select(.closed_at >= $since or (.closed_at >= $keyed_since and tickets != "")) | row' "$page_file" >> "$pulls_file"
        local oldest
        oldest=$(jq -r '.[-1].updated_at // ""' "$page_file")
        if [ -z "$oldest" ] || [[ "$oldest" < "$keyed_since" ]]; then
            break
        fi
        page=$((page + 1))
    done

    if [ -n "$keys" ]; then
        gh api --paginate "repos/$PULL_REQUEST_REPOSITORY/pulls?state=open&per_page=100" \
            | jq -r --arg keys "$keys" "$PULL_REQUEST_FILTERS"' .[] | select(tickets != "") | row' >> "$pulls_file"
    fi

    awk -F'\t' '!seen[$1]++ { print $1, $2 }' "$pulls_file" | while read -r number closed_at; do
        gh api --paginate "repos/$PULL_REQUEST_REPOSITORY/pulls/$number/commits?per_page=100" \
            | jq -r --arg number "$number" '.[] | [$number, (.commit.author.email | ascii_downcase), .commit.author.date, (.commit.message | split("\n\n")[0] | gsub("\n"; " "))] | @tsv' >> "$pull_commits_file"
        if [ -n "$closed_at" ]; then
            local range
            range=$(gh api --paginate "repos/$PULL_REQUEST_REPOSITORY/issues/$number/comments?per_page=100" \
                | jq -r --arg repository "$PULL_REQUEST_REPOSITORY" '.[] | select(.user.login == ($repository | split("/")[0])) | (.body // "") | capture($repository + "/compare/(?<range>[0-9a-f]+\\.\\.\\.[0-9a-f]+)") | .range' \
                | tail -n 1)
            local head="${range#*...}"

            # A range whose head is not on the local master either predates
            # BASE, so it holds no listed commit, or links a push that never
            # happened. A base that predates the clone is replaced by BASE.

            if [ -n "$range" ] && git cat-file -e "$head^{commit}" 2> /dev/null; then
                local base="${range%...*}"
                git cat-file -e "$base^{commit}" 2> /dev/null || base="$BASE"
                git rev-list "$head" "^$base" | awk -v number="$number" '{ print number "\t" $0 }' >> "$ranges_file"
            fi
        fi
    done

    awk -F'\t' -v brian="$BRIAN_EMAIL" -v jira_projects="$JIRA_PROJECTS" -v jira_url="$JIRA_URL" -v members="$TEAM_MEMBERS" -v regen_subject="$REGEN_SUBJECT" -v release_subjects="$RELEASE_SUBJECTS" -v repository="$PULL_REQUEST_REPOSITORY" -v team="$TEAM_REPOSITORY" '
        BEGIN {
            split("✅ ⚠️ 🚨 🤔 ❌ ❔ 📦", marks, " ")
            ticket = jira_projects
            gsub(/ /, "|", ticket)
            ticket = "(" ticket ")-[0-9]+"
            split(tolower(members), names, " ")
            for (i = 1; i in names; i++) { member[names[i]] = 1 }
            meaning["✅"] = "forwarded from " substr(team, 1, index(team, "/") - 1)
            meaning["⚠️"] = "sent directly by a team member"
            meaning["🚨"] = "from another team"
            meaning["🤔"] = "pull request guessed by ticket"
            meaning["❌"] = "no pull request found"
            meaning["❔"] = "no pull request found for Brian'\''s commits"
            meaning["📦"] = "release commits, no pull request expected"
        }
        function cell(text) {
            gsub(/\|/, "\\|", text)
            gsub(/</, "\\&lt;", text)
            gsub(/@/, "@\342\200\213", text)
            return text
        }
        function jira(text,    key, out) {
            out = ""
            while (match(text, ticket)) {
                key = substr(text, RSTART, RLENGTH)
                out = out substr(text, 1, RSTART - 1) "[" key "](" jira_url key ")"
                text = substr(text, RSTART + RLENGTH)
            }
            return out text
        }
        function link(reference,    parts) {
            split(reference, parts, /[\/#]/)
            return "[" parts[1] "#" parts[3] "](https://redirect.github.com/" parts[1] "/" parts[2] "/pull/" parts[3] ")"
        }
        function pull_cell(pull) {
            return link(repository "#" pull) (closed_at[pull] == "" ? " (open)" : "") " - " jira(cell(title[pull]))
        }
        function row(mark, pull, from, commits) {
            used[mark] = 1
            print "| " mark " | " pull " | " from " |" commits " |"
        }
        function likely_pull(subject, threshold,    after, best, count, i, number, p, pulls, rest) {
            after = 0
            best = ""
            rest = subject
            while (match(rest, /[A-Z][A-Z0-9]+-[0-9]+/)) {
                number = substr(rest, RSTART, RLENGTH)
                sub(/.*-/, "", number)
                rest = substr(rest, RSTART + RLENGTH)
                count = split(by_ticket[number], pulls, " ")
                for (i = 1; i <= count; i++) {
                    p = pulls[i]
                    if (closed_at[p] == "") { continue }
                    if (closed_at[p] >= threshold) {
                        if (!after || closed_at[p] < closed_at[best]) { after = 1; best = p }
                    }
                    else if (!after && (best == "" || closed_at[p] > closed_at[best])) { best = p }
                }
            }
            return best
        }
        FILENAME == ARGV[1] {
            closed_at[$1] = $2; origin[$1] = $3; title[$1] = $4; author[$1] = $5
            count = split($6, numbers, " ")
            for (i = 1; i <= count; i++) { by_ticket[numbers[i]] = by_ticket[numbers[i]] " " $1 }
            next
        }
        FILENAME == ARGV[2] { if (!($2 in ranged)) ranged[$2] = $1; next }
        FILENAME == ARGV[3] { authored[$2, $3, $4] = authored[$2, $3, $4] " " $1; next }
        {
            pull = ""
            if ($2 in ranged) {
                pull = ranged[$2]
            }
            else {
                count = split(authored[tolower($3), $4, $6], candidates, " ")
                for (i = 1; i <= count; i++) {
                    p = candidates[i]
                    if (closed_at[p] != "" && closed_at[p] >= $5 && (pull == "" || closed_at[p] < closed_at[pull])) { pull = p }
                }
                for (i = 1; pull == "" && i <= count; i++) {
                    p = candidates[i]
                    if (closed_at[p] == "") { pull = p }
                }
            }
            if (pull != "") {
                if (!(pull in listed)) { order[++size] = pull }
                listed[pull] = listed[pull] " " $1
            }
            else if (tolower($3) != brian) { missing_commits = missing_commits " " $1 }
            else if (tolower($6) ~ release_subjects) { release_commits = release_commits " " $1 }
            else if ((pull = likely_pull($6, $5)) != "") {
                if (!(pull in guessed)) { guess_order[++guesses] = pull }
                guessed[pull] = guessed[pull] " " $1
            }
            else if (tolower($6) ~ regen_subject) { release_commits = release_commits " " $1 }
            else { brian_commits = brian_commits " " $1 }
        }
        END {
            print "#### Pull requests"
            print "| | Pull request | From | Commits |"
            print "| --- | --- | --- | --- |"
            for (i = 1; i <= size; i++) {
                pull = order[i]
                if (origin[pull] == "") {
                    mark = "🚨"
                    if (tolower(author[pull]) in member) { mark = "⚠️" }
                    from = "direct" (author[pull] != "" ? ", " author[pull] : "")
                }
                else { mark = index(origin[pull], team "#") == 1 ? "✅" : "🚨"; from = link(origin[pull]) }
                row(mark, pull_cell(pull), from, listed[pull])
            }
            if (missing_commits != "") { row("❌", "No pull request found", "", missing_commits) }
            for (i = 1; i <= guesses; i++) { row("🤔", pull_cell(guess_order[i]), "Brian'\''s commits, guessed by ticket", guessed[guess_order[i]]) }
            if (brian_commits != "") { row("❔", "Brian'\''s commits, no pull request found", "", brian_commits) }
            if (release_commits != "") { row("📦", "Brian'\''s release commits, no pull request expected", "", release_commits) }
            legend = ""
            for (i = 1; i in marks; i++) {
                if (marks[i] in used) { legend = legend (legend == "" ? "" : " · ") marks[i] " " meaning[marks[i]] }
            }
            print ""
            print legend
            print ""
        }
    ' "$pulls_file" "$ranges_file" "$pull_commits_file" "$commits_file"
}

write_title() {
    local title
    title=$(awk '$2 == "-" && $4 == "-" && $5 ~ /^[A-Z][A-Z0-9]+-[0-9]+$/ && !seen[$5]++ { tickets = tickets (tickets == "" ? "" : ", ") $5 } END { print "Changes" (tickets == "" ? "" : ": " tickets) }' "$THREAD_LOCAL_SECTIONS" "$FOLDER_SECTIONS")
    if [ ${#title} -gt 250 ]; then
        title="${title:0:240}"
        title="${title%,*}, …"
    fi
    echo "$title"
}

awk '$2 == "-" && !seen[$1]++ { print $1 }' "$FOLDER_SECTIONS" "$THREAD_LOCAL_SECTIONS" > "$LISTED_COMMITS"

if [ -s "$LISTED_COMMITS" ]; then
    find_pull_requests
fi

cat "$THREAD_LOCAL_SECTIONS"

if [ -s "$THREAD_LOCAL_SECTIONS" ] && [ -s "$FOLDER_SECTIONS" ]; then
    echo "---"
    echo ""
fi

cat "$FOLDER_SECTIONS"

if [ -n "$TITLE_FILE" ]; then
    write_title > "$TITLE_FILE"
fi
