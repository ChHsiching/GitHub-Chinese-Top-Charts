#!/bin/bash

# Sync overall chart data from Classified repository to current repository
# Convert overall chart data format to suit current repository format
#
# Usage:
#   ./scripts/sync_from_classified.sh      # Normal sync execution
#   ./scripts/sync_from_classified.sh --safe  # Safe mode, check only without execution

set -e  # Exit immediately on error

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Error handling function
handle_error() {
    log "Error: $1"
    exit 1
}

# Format stars function
format_stars() {
    local stars=$1
    if [[ $stars -ge 1000 ]]; then
        # Convert to k format, keep 1 decimal place
        echo "$(echo "scale=1; $stars/1000" | bc 2>/dev/null || echo $((stars/1000)))k"
    else
        echo "$stars"
    fi
}

# Format date function
format_date() {
    local date_str=$1
    # Convert YYYY-MM-DD to MM/DD format
    if [[ $date_str =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
        echo "${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
    else
        echo "$date_str"
    fi
}

# Simplify description function
simplify_description() {
    local desc=$1
    # Limit description length, keep first 100 characters
    if [[ ${#desc} -gt 100 ]]; then
        echo "${desc:0:100}..."
    else
        echo "$desc"
    fi
}

# Configuration variables
CLASSIFIED_REPO_PATH="../GitHub-Chinese-Top-Charts-Classified"
CLASSIFIED_DATA_PATH="${CLASSIFIED_REPO_PATH}/content/charts/overall/software/All-Language.md"
TEMP_DIR="/tmp/sync-data-$(date +%s)"
SYNC_BRANCH="sync-data"
LOG_FILE="sync.log"
SAFE_MODE=false

# Check safe mode parameter
if [ "$1" = "--safe" ] || [ "$1" = "-s" ]; then
    SAFE_MODE=true
    log "Safe mode enabled - Check only without actual execution"
fi

# Cleanup function
cleanup() {
    log "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
    # Clean up sync.log file
    if [ -f "sync.log" ]; then
        rm -f sync.log 2>/dev/null || true
    fi
    log "Cleanup completed"
}

# Set trap to ensure cleanup when script exits
trap cleanup EXIT

# Start sync
log "=== Starting data sync from Classified repository ==="
log "Data source: $CLASSIFIED_DATA_PATH"

# Check current Git repository status
if [[ ! -d ".git" ]]; then
    handle_error "Current directory is not a Git repository"
fi

# Check if Git working directory is clean
STATUS_OUTPUT=$(git status --porcelain)
# Filter out common temporary and untracked files that can be safely ignored
FILTERED_STATUS=$(echo "$STATUS_OUTPUT" | grep -v -E "(^\?\? sync\.log$|^\?\? SYNC_STATUS\.md$|^\?\? \.DS_Store$|^\?\? Thumbs\.db$)" || true)
if [[ -n "$FILTERED_STATUS" ]]; then
    log "Working directory status:"
    echo "$STATUS_OUTPUT"
    handle_error "Working directory is not clean, please commit or stage changes"
fi

# Get current branch
CURRENT_BRANCH=$(git branch --show-current)
if [ -z "$CURRENT_BRANCH" ]; then
    CURRENT_BRANCH="main"  # Default branch
fi
log "Current branch: $CURRENT_BRANCH"

# Check Classified repository and data files
if [[ ! -d "$CLASSIFIED_REPO_PATH" ]]; then
    handle_error "Classified repository does not exist: $CLASSIFIED_REPO_PATH"
fi

if [[ ! -f "$CLASSIFIED_DATA_PATH" ]]; then
    handle_error "Classified data file does not exist: $CLASSIFIED_DATA_PATH"
fi

# If safe mode, check only without execution
if [ "$SAFE_MODE" = true ]; then
    log "[Safe Mode] Checking data source..."
    if [[ -f "$CLASSIFIED_DATA_PATH" ]]; then
        TOTAL_LINES=$(grep -c "^\|" "$CLASSIFIED_DATA_PATH" || echo "0")
        log "[Safe Mode] Classified data file contains $TOTAL_LINES items"

        # Show first 5 items
        log "[Safe Mode] First 5 items preview:"
        grep "^\|" "$CLASSIFIED_DATA_PATH" | head -n 5 | while read line; do
            log "[Safe Mode] $line"
        done
    fi

    log "[Safe Mode] Checking current README.md..."
    if [[ -f "README.md" ]]; then
        CURRENT_LINES=$(grep -c "^\|" README.md || echo "0")
        log "[Safe Mode] Current README.md contains $CURRENT_LINES items"
    fi

    log "[Safe Mode] Check completed, no actual operations executed"
    exit 0
fi

# Create temporary working directory
mkdir -p "$TEMP_DIR"

# Backup current README.md
log "Backing up current README.md..."
cp README.md "$TEMP_DIR/README.md.backup"

# Check if sync-data branch exists
if git show-ref --verify --quiet "refs/heads/$SYNC_BRANCH"; then
    log "Deleting existing $SYNC_BRANCH branch..."
    git branch -D "$SYNC_BRANCH"
fi

# Create new sync-data branch
log "Creating sync branch: $SYNC_BRANCH"
git checkout --orphan "$SYNC_BRANCH"

# Clean up working directory
git rm -rf . 2>/dev/null || true
log "Working directory cleanup completed"

# Restore all files (except README.md)
log "Restoring files..."
cp -r "$TEMP_DIR/README.md.backup" README.md 2>/dev/null || true

# Restore other important files
IMPORTANT_FILES=(".gitattributes" "LICENSE" "README-Part2.md" "CLAUDE.md" ".github" "scripts")
for file in "${IMPORTANT_FILES[@]}"; do
    if [ -e "../$CURRENT_BRANCH/$file" ]; then
        log "Restoring file: $file"
        cp -r "../$CURRENT_BRANCH/$file" . 2>/dev/null || true
    fi
done

# Parse Classified data and convert format
log "Parsing and converting data format..."

# Create temporary data file
TEMP_DATA_FILE="$TEMP_DIR/converted_data.md"

# Extract and convert data table
log "Starting data conversion..."
in_table=false
row_count=0

# Add table header
echo "|#|Repository|Description|Stars|Language|Updated|" >> "$TEMP_DATA_FILE"
echo "|:-|:-|:-|:-|:-|:-|" >> "$TEMP_DATA_FILE"

while IFS= read -r line; do
    if [[ $line =~ ^\|\s*[0-9]+\s*\|\s*\[.*\]\(.*\)\s*\|.*\|.*\|.*\|.*\|$ ]]; then
        # Data row, need to convert format
        # Use cut to parse data row
        rank=$(echo "$line" | cut -d'|' -f2 | tr -d ' ')
        repo_part=$(echo "$line" | cut -d'|' -f3)
        description=$(echo "$line" | cut -d'|' -f4)
        stars=$(echo "$line" | cut -d'|' -f5 | tr -d ' ')
        language=$(echo "$line" | cut -d'|' -f6 | tr -d ' ')
        updated=$(echo "$line" | cut -d'|' -f7 | tr -d ' ')

        # Parse repo_name and repo_url from repo part
        repo_name=$(echo "$repo_part" | sed 's/^\[//; s/\].*$//')
        repo_url=$(echo "$repo_part" | sed 's/^.*(\(.*\))/\1/')

        # Validate parsing result
        if [[ -z "$repo_name" || -z "$repo_url" ]]; then
            continue
        fi

        # Format conversion
        formatted_stars=$(format_stars "$stars")
        # Keep original date format YYYY-MM-DD
        simplified_desc=$(simplify_description "$description")

        # Rebuild line
        new_line="|$rank|[$repo_name]($repo_url)|$simplified_desc|$formatted_stars|$language|$updated|"
        echo "$new_line" >> "$TEMP_DATA_FILE"

        row_count=$((row_count + 1))
        if [[ $((row_count % 10)) -eq 0 ]]; then
            log "Processed $row_count items..."
        fi
    fi
done < "$CLASSIFIED_DATA_PATH"

log "Data conversion completed, processed $row_count items total"

# Split data and update README.md
log "Splitting data and updating README.md..."

# Read current README.md content
README_CONTENT=$(cat README.md)

# Update "Last updated time" at the beginning of README.md
CURRENT_DATE=$(date '+%Y年%m月%d日')
README_CONTENT=$(echo "$README_CONTENT" | sed "s/最近更新时间为.*月.*日/最近更新时间为$CURRENT_DATE/")

# Find start and end of All Language section
ALL_LANG_START=$(echo "$README_CONTENT" | grep -n "^## All Language$" | cut -d: -f1)
if [[ -z "$ALL_LANG_START" ]]; then
    handle_error "All Language section not found in README.md"
fi

# Find next major heading as end position
ALL_LANG_END=$(echo "$README_CONTENT" | tail -n +$((ALL_LANG_START + 1)) | grep -n "^## " | head -n 1 | cut -d: -f1)

if [[ -z "$ALL_LANG_END" ]]; then
    # If no next heading found, go to end of file
    ALL_LANG_END=$(echo "$README_CONTENT" | wc -l)
else
    ALL_LANG_END=$((ALL_LANG_START + ALL_LANG_END - 1))
fi

# Split data: first 50 in README.md, rest in README-Part2.md
HEAD_COUNT=50
TEMP_DATA_FILE_PART2="$TEMP_DIR/converted_data_part2.md"

# Extract header
head -n 2 "$TEMP_DATA_FILE" > "$TEMP_DATA_FILE_PART2"

# Extract data and split
TOTAL_TABLE_LINES=$(tail -n +3 "$TEMP_DATA_FILE" | wc -l)
MAIN_TABLE_LINES=$(tail -n +3 "$TEMP_DATA_FILE" | head -n $HEAD_COUNT)
PART2_TABLE_LINES=$(tail -n +3 "$TEMP_DATA_FILE" | tail -n +$((HEAD_COUNT + 1)))

# Build README.md
log "Building README.md..."
HEAD_CONTENT=$(echo "$README_CONTENT" | head -n $((ALL_LANG_START - 1)))

# Update time in HEAD_CONTENT
HEAD_CONTENT=$(echo "$HEAD_CONTENT" | sed "s/最近更新时间为.*月.*日/最近更新时间为$CURRENT_DATE/")

echo "$HEAD_CONTENT" > README.md
echo "" >> README.md
echo "## All Language" >> README.md
echo "" >> README.md

# Add header and first 50 data
head -n 2 "$TEMP_DATA_FILE" >> README.md
echo "$MAIN_TABLE_LINES" >> README.md

# Add link to README-Part2.md
echo "" >> README.md
echo "View complete ranking at: [README-Part2.md](README-Part2.md)" >> README.md

# Keep content after All Language section (if exists)
TAIL_START=$((ALL_LANG_END + 1))
TOTAL_LINES=$(echo "$README_CONTENT" | wc -l)

if [[ $TAIL_START -le $TOTAL_LINES ]]; then
    echo "" >> README.md
    echo "$README_CONTENT" | tail -n +$TAIL_START >> README.md
fi

# Build README-Part2.md
log "Building README-Part2.md..."
echo "# One README can't contain everything, second README continues" > README-Part2.md
echo "" >> README-Part2.md
echo "## All Language (continued)" >> README-Part2.md
echo "" >> README-Part2.md

# Add header and remaining data
cat "$TEMP_DATA_FILE_PART2" >> README-Part2.md
echo "$PART2_TABLE_LINES" >> README-Part2.md

log "README.md and README-Part2.md update completed"

# Ensure no sync.log file
if [ -f "sync.log" ]; then
    rm -f sync.log 2>/dev/null || true
fi

# Add all changes
log "Adding files to Git..."
git add .

# Commit changes
COMMIT_MSG="Auto sync from Classified repository - $(date '+%Y-%m-%d %H:%M:%S')

Data source: $CLASSIFIED_DATA_PATH
Processed items: $row_count
Sync time: $(date)"

log "Committing changes..."
if ! git commit -m "$COMMIT_MSG"; then
    handle_error "Commit failed"
fi
log "Commit completed"

# Show sync results
log "=== Sync completed ==="
log "Latest commits:"
git log --oneline -n 3

# Show file statistics
if command -v wc &> /dev/null; then
    TOTAL_FILES=$(find . -name "*.md" -not -path "./.git/*" | wc -l)
    log "Total Markdown files: $TOTAL_FILES"
fi

# Show table row count
TABLE_ROWS=$(grep -c "^\|.*\|.*\|.*\|.*\|.*\|" README.md || echo "0")
log "Number of table rows in README.md: $TABLE_ROWS"

log "Sync script execution completed"
exit 0