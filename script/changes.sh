grep '@liferay-database-infra' .github/CODEOWNERS | awk '{print $1}' | while read -r folder; do
    commits=$(git log $1..HEAD --pretty=format:'%h %ae %s' -- "$folder")
    if [ -n "$commits" ]; then
        echo "#### Changes in $folder"
        echo "$commits"
        echo ""
    fi
done
