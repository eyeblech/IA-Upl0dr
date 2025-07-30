#!/usr/bin/env bash
# ====================================================
# IA Uploader v4.3 - Fixed Defaults
# Features:
# - Media type default works immediately
# - Metadata defaults apply correctly
# - All other functionality preserved
# ====================================================

set -eo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
MAX_PARALLEL=2
LOG_FILE="/tmp/ia_uploader_$(date +%s).log"
touch "$LOG_FILE"

cleanup() { rm -f "$LOG_FILE"; }
trap cleanup EXIT

check_deps() {
    for cmd in ia pv; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}Error:${NC} Missing '$cmd'"
            [[ "$cmd" == "ia" ]] && echo "Install: pip install internetarchive"
            exit 1
        fi
    done
}

collect_metadata() {
    local file="$1"
    local basefile="$(basename "$file")"
    local default_year=$(date +%Y)
    
    echo -e "\n${CYAN}=== Metadata for: ${YELLOW}$basefile${NC} ===${NC}"
    
    # Title (default: filename without extension)
    local default_title="${basefile%.*}"
    read -p "Title [default: $default_title]: " title
    title="${title:-$default_title}"
    
    # Description
    read -p "Description [default: None]: " description
    description="${description:-None}"
    
    # Creator
    read -p "Creator [default: Anonymous]: " creator
    creator="${creator:-Anonymous}"
    
    # Year
    read -p "Year [default: $default_year]: " year
    year="${year:-$default_year}"
    
    # Topics
    read -p "Topics (comma separated) [default: None]: " topics
    topics="${topics:-None}"
    
    # Media Type - FIXED DEFAULT HANDLING
    echo -e "\n${BLUE}Select Media Type:${NC}"
    echo "1) Movies (Video)"
    echo "2) Audio"
    echo "3) Text"
    echo "4) Other"
    read -p "Your choice [1]: " choice
    choice="${choice:-1}"  # Default to 1 if empty
    
    case $choice in
        1) 
            mediatype="movies"
            collection="opensource_movies"
            ;;
        2) 
            mediatype="audio"
            collection="opensource_audio"
            ;;
        3) 
            mediatype="texts"
            collection="opensource"
            ;;
        4) 
            read -p "Enter custom mediatype: " mediatype
            collection="opensource"
            ;;
        *) 
            # Fallback to movies
            mediatype="movies"
            collection="opensource_movies"
            ;;
    esac
    
    # Store with full path for later lookup
    echo "$file|$title|$description|$creator|$year|$topics|$mediatype|$collection" >> "$LOG_FILE"
}

upload_file() {
    local file="$1"
    local identifier="$2"
    local metadata="$3"
    
    IFS='|' read -r -a meta <<< "$metadata"
    local basefile="$(basename "$file")"
    
    echo -e "\n${GREEN}Starting upload:${NC} ${YELLOW}$basefile${NC}"
    echo -e "${BLUE}Title:${NC} ${meta[1]}"
    echo -e "${BLUE}Creator:${NC} ${meta[3]}"
    echo -e "${BLUE}Year:${NC} ${meta[4]}"
    echo -e "${BLUE}Size:${NC} $(du -h "$file" | cut -f1)"
    
    # Use pv with quoted file path
    pv -pet -N "$basefile" "$file" | ia upload "$identifier" - \
        --remote-name="$basefile" \
        --metadata="title:${meta[1]}" \
        --metadata="description:${meta[2]}" \
        --metadata="creator:${meta[3]}" \
        --metadata="date:${meta[4]}" \
        --metadata="subject:${meta[5]}" \
        --metadata="mediatype:${meta[6]}" \
        --metadata="collection:${meta[7]}"
    
    echo -e "${GREEN}✅ Upload complete${NC}"
}

main() {
    check_deps
    
    if [[ -d "$1" ]]; then
        echo -e "${CYAN}=== Processing directory:${NC} $1 ==="
        
        # Get files array with full paths (handling spaces)
        files=()
        while IFS=  read -r -d $'\0' file; do
            files+=("$file")
        done < <(find "$1" -type f -print0)
        
        total_files=${#files[@]}
        [ $total_files -eq 0 ] && { echo -e "${RED}Error:${NC} No files found"; exit 1; }
        
        echo -e "${GREEN}Found ${YELLOW}$total_files${GREEN} files${NC}"
        
        # Metadata strategy - FIXED DEFAULT HANDLING
        echo -e "\n${CYAN}=== Metadata Options ===${NC}"
        echo "1) Same-metadata-for-all-files"
        echo "2) Different-metadata-per-file"
        read -p "Your choice [1]: " strategy_choice
        strategy_choice="${strategy_choice:-1}"  # Default to 1 if empty
        
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
                # Default to same metadata
                echo -e "\n${BLUE}Using same metadata for all files:${NC}"
                collect_metadata "${files[0]}"
                first_meta=$(tail -n1 "$LOG_FILE")
                for file in "${files[@]:1}"; do
                    echo "${file}|${first_meta#*|}" >> "$LOG_FILE"
                done
                ;;
        esac
        
        # Upload phase
        echo -e "\n${CYAN}=== Starting uploads (max $MAX_PARALLEL at once) ===${NC}"
        
        # Process files in batches
        for ((i=0; i<${#files[@]}; i++)); do
            file="${files[$i]}"
            # Lookup metadata by full path
            metadata=$(grep -F "${file}|" "$LOG_FILE")
            
            # Generate a unique identifier for each file
            upload_file "$file" "${2:-upload-$(date +%Y%m%d)}-$i" "$metadata" &
            
            # Limit parallel uploads
            if [[ $(jobs -r -p | wc -l) -ge $MAX_PARALLEL ]]; then
                wait -n
            fi
        done
        wait
        
    elif [[ -f "$1" ]]; then
        echo -e "${CYAN}=== Processing single file ===${NC}"
        collect_metadata "$1"
        upload_file "$1" "${2:-upload-$(date +%Y%m%d)}" "$(tail -n1 "$LOG_FILE")"
    else
        echo -e "${RED}Error:${NC} Invalid input - must be file or directory"
        exit 1
    fi
    
    echo -e "\n${GREEN}✅ All uploads completed successfully!${NC}"
    echo -e "${CYAN}View your files at:${NC} https://archive.org/details/${2:-upload-$(date +%Y%m%d)}*"
}

main "$@"
