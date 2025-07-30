#!/usr/bin/env bash
# ====================================================
# Internet Archive Uploader with Metadata & Progress Bar
# Usage: ./archive_upload.sh <file_or_folder> [identifier]
# ====================================================

set -eo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

FILE_OR_FOLDER="$1"
IDENTIFIER="$2"

show_help() {
    echo -e "${GREEN}Usage:${NC} $0 <file_or_folder> [identifier]"
    echo -e "\n${YELLOW}Examples:${NC}"
    echo "  $0 my_video.mp4"
    echo "  $0 ./documents my-book-archive"
    exit 0
}

# Validate inputs
if [[ -z "$FILE_OR_FOLDER" ]] || [[ "$1" == "--help" ]]; then
    show_help
fi

# Check dependencies
for cmd in ia pv; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}Error:${NC} '$cmd' not found. Install with:"
        echo "  pip install internetarchive (for 'ia')"
        echo "  sudo apt-get install pv (for progress bar)"
        exit 1
    fi
done

# Generate identifier if not provided
if [[ -z "$IDENTIFIER" ]]; then
    IDENTIFIER="upload-$(date +%Y%m%d-%H%M%S)"
    echo -e "${YELLOW}No identifier provided. Using:${NC} $IDENTIFIER"
fi

# Metadata prompt
echo -e "\n${GREEN}Enter metadata for this upload:${NC}"
read -p "Title: " TITLE
read -p "Description: " DESCRIPTION
read -p "Creator: " CREATOR
read -p "Year [$(date +%Y)]: " YEAR
YEAR=${YEAR:-$(date +%Y)}
read -p "Topics (comma-separated keywords): " TOPICS

# Media type selection
echo -e "\n${GREEN}Select Media Type:${NC}"
echo "1) Movies (Video)"
echo "2) Audio"
echo "3) Text"
echo "4) Other"
read -p "Choice [1]: " CHOICE
case ${CHOICE:-1} in
    1) MEDIATYPE="movies"; COLLECTION="opensource_movies" ;;
    2) MEDIATYPE="audio"; COLLECTION="opensource_audio" ;;
    3) MEDIATYPE="texts"; COLLECTION="opensource" ;;
    4) read -p "Enter custom mediatype: " MEDIATYPE
       COLLECTION="opensource" ;;
esac

# Metadata arguments
META_ARGS=(
    --metadata="title:$TITLE"
    --metadata="description:$DESCRIPTION"
    --metadata="creator:$CREATOR"
    --metadata="date:$YEAR"
    --metadata="subject:$TOPICS"
    --metadata="mediatype:$MEDIATYPE"
    --metadata="collection:$COLLECTION"
)

upload_file() {
    local file="$1"
    echo -e "\n${GREEN}Uploading:${NC} $(basename "$file")"
    SIZE=$(stat -c%s "$file")
    pv -s "$SIZE" "$file" | ia upload "$IDENTIFIER" - \
        --remote-name="$(basename "$file")" \
        "${META_ARGS[@]}"
}

# Upload logic
if [[ -d "$FILE_OR_FOLDER" ]]; then
    echo -e "${YELLOW}Uploading folder contents...${NC}"
    for f in "$FILE_OR_FOLDER"/*; do
        [[ -f "$f" ]] && upload_file "$f"
    done
else
    [[ ! -f "$FILE_OR_FOLDER" ]] && { echo -e "${RED}Error:${NC} File not found."; exit 1; }
    upload_file "$FILE_OR_FOLDER"
fi

echo -e "\n${GREEN}✅ Upload complete!${NC}"
echo -e "View at: https://archive.org/details/$IDENTIFIER"
