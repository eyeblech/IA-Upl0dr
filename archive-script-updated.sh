#!/usr/bin/env bash
# ====================================================
# IA Power Uploader v6.2 - Crash-Proof Edition
# Features:
# - Writes everything to log files
# - Can resume after terminal crash
# - No unexpected exits
# ====================================================

# Don't exit on errors - we want to log them instead
set +e
set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Configuration
MAX_PARALLEL=2
MAX_RETRIES=3
RETRY_DELAY=10
OMDB_API_KEY="3939e340"

# Create unique session ID
SESSION_ID="ia_upload_$(date +%Y%m%d_%H%M%S)"
SESSION_DIR="/tmp/${SESSION_ID}"
mkdir -p "$SESSION_DIR"

LOG_FILE="${SESSION_DIR}/metadata.log"
UPLOAD_REPORT="${SESSION_DIR}/upload_report.txt"
SESSION_LOG="${SESSION_DIR}/session.log"

# Log everything
exec > >(tee -a "$SESSION_LOG") 2>&1

cleanup() { 
    echo -e "\n${YELLOW}Session saved to: ${SESSION_DIR}${NC}"
    echo -e "${YELLOW}To resume later, check logs in that directory${NC}"
}
trap cleanup EXIT

check_deps() {
    local missing=0
    for cmd in ia pv jq curl; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}Error:${NC} Missing '$cmd'"
            missing=1
        fi
    done
    
    if [[ $missing -eq 1 ]]; then
        echo -e "${YELLOW}Install missing dependencies and try again${NC}"
        exit 1
    fi
}

# FIXED: Better filename parsing that handles special characters
parse_filename() {
    local filename="$1"
    local basename="${filename%.*}"
    
    # Remove path and keep just filename
    basename=$(basename "$basename")
    
    # Replace common separators with spaces
    local clean_name=$(echo "$basename" | sed 's/[_\.-]/ /g' | sed 's/[#]//g' | sed 's/  */ /g')
    
    # Extract year (1971, 2025, etc.) - only if it's a 4-digit number
    local year=""
    if [[ "$clean_name" =~ [^0-9](19[0-9]{2}|20[0-9]{2})[^0-9] ]] || [[ "$clean_name" =~ ^(19[0-9]{2}|20[0-9]{2})$ ]]; then
        year="${BASH_REMATCH[1]}"
    fi
    
    # Extract quality indicators
    local quality=""
    if [[ "$clean_name" =~ (720p|1080p|4k|2160p|HD|BluRay|WEB-DL|WEBRip|HDRip|x264|x265) ]]; then
        quality="${BASH_REMATCH[1]}"
    fi
    
    # Remove year and quality for title search
    local search_title="$clean_name"
    if [[ -n "$year" ]]; then
        search_title=$(echo "$search_title" | sed "s/$year//g")
    fi
    if [[ -n "$quality" ]]; then
        search_title=$(echo "$search_title" | sed "s/$quality//gi")
    fi
    search_title=$(echo "$search_title" | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
    
    # If search title is empty, use the original basename
    if [[ -z "$search_title" ]]; then
        search_title="$basename"
    fi
    
    # Return as eval-safe strings
    echo "search_title='$search_title'"
    echo "suggested_year='$year'"
    echo "suggested_quality='$quality'"
}

# Search OMDb API
search_omdb() {
    local query="$1"
    local year="$2"
    
    # URL encode the query
    local encoded_query=$(echo "$query" | sed 's/ /%20/g')
    
    # Build URL with optional year
    local url="http://www.omdbapi.com/?s=${encoded_query}&apikey=${OMDB_API_KEY}"
    [[ -n "$year" ]] && url="${url}&y=${year}"
    
    # Fetch and parse
    local response=$(curl -s "$url")
    
    # Check if response is valid JSON
    if ! echo "$response" | jq empty 2>/dev/null; then
        return 1
    fi
    
    local total_results=$(echo "$response" | jq -r '.totalResults // "0"')
    
    if [[ "$total_results" == "0" ]] || [[ "$(echo "$response" | jq -r '.Response')" == "False" ]]; then
        return 1
    fi
    
    echo "$response"
}

# Fetch full movie details
fetch_movie_details() {
    local imdb_id="$1"
    local url="http://www.omdbapi.com/?i=${imdb_id}&apikey=${OMDB_API_KEY}&plot=full"
    
    curl -s "$url"
}

# Interactive movie selection
select_movie() {
    local search_response="$1"
    local filename="$2"
    
    # Parse search results
    local titles=()
    local years=()
    local imdb_ids=()
    
    while IFS= read -r line; do
        [[ -n "$line" ]] && titles+=("$line")
    done < <(echo "$search_response" | jq -r '.Search[]?.Title // empty' 2>/dev/null)
    
    while IFS= read -r line; do
        [[ -n "$line" ]] && years+=("$line")
    done < <(echo "$search_response" | jq -r '.Search[]?.Year // empty' 2>/dev/null)
    
    while IFS= read -r line; do
        [[ -n "$line" ]] && imdb_ids+=("$line")
    done < <(echo "$search_response" | jq -r '.Search[]?.imdbID // empty' 2>/dev/null)
    
    local count=${#titles[@]}
    
    if [[ $count -eq 0 ]]; then
        return 1
    elif [[ $count -eq 1 ]]; then
        echo -e "${GREEN}Found one match:${NC} ${titles[0]} (${years[0]})"
        read -p "Use this? [Y/n]: " confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            return 1
        fi
        echo "${imdb_ids[0]}"
        return 0
    else
        echo -e "\n${CYAN}Multiple matches found for:${NC} $filename"
        for i in "${!titles[@]}"; do
            echo -e "${YELLOW}$((i+1)))${NC} ${titles[$i]} ${GREEN}(${years[$i]})${NC}"
        done
        echo -e "${YELLOW}s)${NC} Skip auto-fill (enter manually)"
        echo -e "${YELLOW}c)${NC} Custom search"
        
        read -p "Select [1]: " choice
        choice="${choice:-1}"
        
        if [[ "$choice" == "s" ]]; then
            return 1
        elif [[ "$choice" == "c" ]]; then
            read -p "Enter custom search term: " custom
            if [[ -n "$custom" ]]; then
                new_response=$(search_omdb "$custom" "")
                if [[ $? -eq 0 ]]; then
                    select_movie "$new_response" "$custom"
                    return $?
                fi
            fi
            return 1
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le $count ]]; then
            echo "${imdb_ids[$((choice-1))]}"
            return 0
        else
            echo "${imdb_ids[0]}"
            return 0
        fi
    fi
}

collect_metadata() {
    local file="$1"
    local basefile="$(basename "$file")"
    local default_year=$(date +%Y)
    
    echo -e "\n${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║${NC}              ${CYAN}METADATA COLLECTION${NC}                      ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}File:${NC} $basefile"
    echo -e "${YELLOW}Session ID:${NC} $SESSION_ID"
    echo -e "${YELLOW}Logs:${NC} $SESSION_DIR"
    
    # Parse filename for suggestions
    local parse_output=$(parse_filename "$basefile")
    eval "$parse_output" 2>/dev/null || true
    
    # Try OMDb lookup
    local use_omdb=true
    local movie_details=""
    local selected_id=""
    
    echo -e "\n${CYAN}▶ OMDb Auto-Fetch${NC}"
    read -p "Search OMDb for metadata? [Y/n]: " search_choice
    search_choice="${search_choice:-Y}"
    
    if [[ "$search_choice" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Searching for:${NC} $search_title ${suggested_year:+($suggested_year)}"
        
        # Try with year first
        search_response=$(search_omdb "$search_title" "$suggested_year")
        if [[ $? -ne 0 ]] && [[ -n "$suggested_year" ]]; then
            echo -e "${YELLOW}No results with year, trying without...${NC}"
            search_response=$(search_omdb "$search_title" "")
        fi
        
        if [[ $? -eq 0 ]] && [[ -n "$search_response" ]]; then
            selected_id=$(select_movie "$search_response" "$basefile")
            if [[ $? -eq 0 ]] && [[ -n "$selected_id" ]]; then
                movie_details=$(fetch_movie_details "$selected_id")
                if [[ -n "$movie_details" ]]; then
                    echo -e "${GREEN}✓ Metadata fetched successfully!${NC}"
                fi
            fi
        else
            echo -e "${YELLOW}No matches found on OMDb.${NC}"
        fi
    fi
    
    # Extract OMDb data if available
    local omdb_title=""
    local omdb_year=""
    local omdb_plot=""
    local omdb_director=""
    local omdb_actors=""
    local omdb_genre=""
    local omdb_type=""
    local omdb_creator=""
    
    if [[ -n "$movie_details" ]]; then
        omdb_title=$(echo "$movie_details" | jq -r '.Title // empty')
        omdb_year=$(echo "$movie_details" | jq -r '.Year // empty')
        omdb_plot=$(echo "$movie_details" | jq -r '.Plot // empty')
        omdb_director=$(echo "$movie_details" | jq -r '.Director // empty')
        omdb_actors=$(echo "$movie_details" | jq -r '.Actors // empty')
        omdb_genre=$(echo "$movie_details" | jq -r '.Genre // empty')
        omdb_type=$(echo "$movie_details" | jq -r '.Type // "movie"')
        
        # Combine director and actors for creator field
        omdb_creator="$omdb_director"
        [[ -n "$omdb_actors" ]] && omdb_creator="${omdb_creator} (with $omdb_actors)"
    fi
    
    echo -e "\n${CYAN}▶ Manual Entry (press Enter to accept defaults)${NC}"
    
    # Title
    local default_title="${omdb_title:-${search_title:-${basefile%.*}}}"
    read -p "Title [default: $default_title]: " title
    title="${title:-$default_title}"
    
    # Description
    local default_desc="${omdb_plot:-None}"
    read -p "Description [default: $default_desc]: " description
    description="${description:-$default_desc}"
    
    # Creator
    local default_creator="${omdb_creator:-Anonymous}"
    read -p "Creator [default: $default_creator]: " creator
    creator="${creator:-$default_creator}"
    
    # Year
    local default_year="${omdb_year:-${suggested_year:-$(date +%Y)}}"
    read -p "Year [default: $default_year]: " year
    year="${year:-$default_year}"
    
    # Topics
    local default_topics="${omdb_genre:-None}"
    read -p "Topics [default: $default_topics]: " topics
    topics="${topics:-$default_topics}"
    
    # Media Type with auto-detection
    echo -e "\n${BLUE}Media Type:${NC}"
    echo "1) Movies (Video)"
    echo "2) Audio"
    echo "3) Text"
    echo "4) Other"
    
    # Auto-detect from OMDb or file extension
    local default_media=1
    if [[ -n "$omdb_type" ]]; then
        case "$omdb_type" in
            movie|series|episode) default_media=1 ;;
            *) default_media=1 ;;
        esac
    else
        local ext="${file##*.}"
        case "${ext,,}" in
            mp4|mkv|avi|mov|wmv|m4v|webm) default_media=1 ;;
            mp3|flac|wav|m4a|ogg|aac) default_media=2 ;;
            pdf|epub|mobi|txt|doc|docx) default_media=3 ;;
            *) default_media=1 ;;
        esac
    fi
    
    read -p "Your choice [$default_media]: " choice
    choice="${choice:-$default_media}"
    
    case $choice in
        1) mediatype="movies"; collection="opensource_movies" ;;
        2) mediatype="audio"; collection="opensource_audio" ;;
        3) mediatype="texts"; collection="opensource" ;;
        4) read -p "Enter custom mediatype: " mediatype; collection="opensource" ;;
        *) mediatype="movies"; collection="opensource_movies" ;;
    esac
    
    # Store with full path
    echo "$file|$title|$description|$creator|$year|$topics|$mediatype|$collection" >> "$LOG_FILE"
}

upload_file_with_retry() {
    local file="$1"
    local identifier="$2"
    local metadata="$3"
    local attempt=1
    
    IFS='|' read -r -a meta <<< "$metadata"
    local basefile="$(basename "$file")"
    
    while [ $attempt -le $MAX_RETRIES ]; do
        if [ $attempt -gt 1 ]; then
            echo -e "\n${YELLOW}Retry attempt $attempt of $MAX_RETRIES for $basefile${NC}"
            echo -e "${BLUE}Waiting $RETRY_DELAY seconds...${NC}"
            sleep $RETRY_DELAY
        fi
        
        echo -e "\n${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║${NC}                 ${GREEN}UPLOADING FILE${NC}                         ${MAGENTA}║${NC}"
        echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
        echo -e "${YELLOW}File:${NC} $basefile"
        echo -e "${YELLOW}Identifier:${NC} $identifier"
        echo -e "${YELLOW}Title:${NC} ${meta[1]}"
        echo -e "${YELLOW}Creator:${NC} ${meta[3]}"
        echo -e "${YELLOW}Year:${NC} ${meta[4]}"
        echo -e "${YELLOW}Topics:${NC} ${meta[5]}"
        echo -e "${YELLOW}Size:${NC} $(du -h "$file" | cut -f1)"
        echo -e "${YELLOW}Attempt:${NC} $attempt of $MAX_RETRIES"
        
        if pv -pet -N "$basefile" "$file" | ia upload "$identifier" - \
            --remote-name="$basefile" \
            --metadata="title:${meta[1]}" \
            --metadata="description:${meta[2]}" \
            --metadata="creator:${meta[3]}" \
            --metadata="date:${meta[4]}" \
            --metadata="subject:${meta[5]}" \
            --metadata="mediatype:${meta[6]}" \
            --metadata="collection:${meta[7]}"; then
            
            echo -e "${GREEN}✅ Upload complete for $basefile${NC}"
            echo "$identifier|$basefile" >> "$UPLOAD_REPORT"
            return 0
        else
            local exit_code=$?
            echo -e "\n${RED}❌ Upload failed with exit code $exit_code${NC}"
            
            if [ $attempt -lt $MAX_RETRIES ]; then
                echo -e "${YELLOW}Will retry in $RETRY_DELAY seconds...${NC}"
            fi
            ((attempt++))
        fi
    done
    
    echo -e "${RED}❌ Failed after $MAX_RETRIES attempts for $basefile${NC}"
    echo "${identifier}|FAILED|$basefile" >> "$UPLOAD_REPORT"
    return 1
}

print_summary() {
    echo -e "\n${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║${NC}               ${GREEN}UPLOAD COMPLETE SUMMARY${NC}                  ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
    
    echo -e "\n${GREEN}✅ Successfully uploaded:${NC}"
    local success_count=0
    if [[ -f "$UPLOAD_REPORT" ]]; then
        while IFS='|' read -r identifier filename; do
            if [[ "$identifier" != *FAILED* ]]; then
                echo -e " • ${YELLOW}$filename${NC}"
                echo -e "   ${BLUE}URL:${NC} https://archive.org/details/$identifier"
                ((success_count++))
            fi
        done < "$UPLOAD_REPORT"
    fi
    
    echo -e "\n${RED}❌ Failed uploads:${NC}"
    local fail_count=0
    if [[ -f "$UPLOAD_REPORT" ]]; then
        while IFS='|' read -r _ status filename; do
            if [[ "$status" == "FAILED" ]]; then
                echo -e " • ${YELLOW}$filename${NC}"
                ((fail_count++))
            fi
        done < "$UPLOAD_REPORT"
    fi
    
    echo -e "\n${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Total: $((success_count + fail_count)) files | ✅ Success: $success_count | ❌ Failed: $fail_count${NC}"
    echo -e "\n${YELLOW}Session logs saved to: ${SESSION_DIR}${NC}"
}

main() {
    check_deps
    
    echo -e "${MAGENTA}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║           INTERNET ARCHIVE POWER UPLOADER                  ║"
    echo "║                                                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${CYAN}Session ID:${NC} $SESSION_ID"
    echo -e "${CYAN}Log directory:${NC} $SESSION_DIR"
    echo -e "${CYAN}To resume after crash, check:${NC} $SESSION_LOG\n"
    
    if [[ -d "$1" ]]; then
        echo -e "${CYAN}📁 Processing directory:${NC} $1"
        
        files=()
        while IFS=  read -r -d $'\0' file; do
            files+=("$file")
        done < <(find "$1" -type f -print0)
        
        total_files=${#files[@]}
        [ $total_files -eq 0 ] && { echo -e "${RED}Error:${NC} No files found"; exit 1; }
        
        echo -e "${GREEN}Found ${YELLOW}$total_files${GREEN} files${NC}"
        
        echo -e "\n${CYAN}=== Metadata Options ===${NC}"
        echo "1) Same-metadata-for-all-files"
        echo "2) Different-metadata-per-file"
        read -p "Your choice [1]: " strategy_choice
        strategy_choice="${strategy_choice:-1}"
        
        case $strategy_choice in
            1)
                echo -e "\n${BLUE}Enter metadata that will apply to ALL files:${NC}"
                collect_metadata "${files[0]}"
                first_meta=$(tail -n1 "$LOG_FILE")
                for file in "${files[@]:1}"; do
                    echo "${file}|${first_meta#*|}" >> "$LOG_FILE"
                done
                ;;
            2)
                echo -e "\n${BLUE}Enter metadata for each file:${NC}"
                for file in "${files[@]}"; do
                    collect_metadata "$file"
                done
                ;;
            *)
                echo -e "\n${BLUE}Using same metadata for all files:${NC}"
                collect_metadata "${files[0]}"
                first_meta=$(tail -n1 "$LOG_FILE")
                for file in "${files[@]:1}"; do
                    echo "${file}|${first_meta#*|}" >> "$LOG_FILE"
                done
                ;;
        esac
        
        echo -e "\n${CYAN}=== Starting uploads (max $MAX_PARALLEL at once) ===${NC}"
        > "$UPLOAD_REPORT"
        
        for ((i=0; i<${#files[@]}; i++)); do
            file="${files[$i]}"
            metadata=$(grep -F "${file}|" "$LOG_FILE")
            identifier="${2:-upload-$(date +%Y%m%d)}-$i"
            
            upload_file_with_retry "$file" "$identifier" "$metadata" &
            
            if [[ $(jobs -r -p | wc -l) -ge $MAX_PARALLEL ]]; then
                wait -n
            fi
        done
        wait
        
    elif [[ -f "$1" ]]; then
        echo -e "${CYAN}🎬 Processing single file:${NC} $1"
        > "$UPLOAD_REPORT"
        collect_metadata "$1"
        identifier="${2:-upload-$(date +%Y%m%d)}"
        upload_file_with_retry "$1" "$identifier" "$(tail -n1 "$LOG_FILE")"
    else
        echo -e "${RED}Error:${NC} Invalid input - must be file or directory"
        exit 1
    fi
    
    print_summary
}

main "$@"
