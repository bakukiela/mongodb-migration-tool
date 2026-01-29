#!/bin/bash

# Simple script to migrate MongoDB database from source to local Docker
# Usage: ./scripts/migrate-database.sh <from-url> <target-url> <database-name>
# Example: ./scripts/migrate-database.sh "mongodb://source:27017" "mongodb://localhost:27017" "mydatabase"

set -e  # Exit on error
set -u  # Exit on undefined variable
set -o pipefail  # Exit on pipe failure

# Cleanup function for temporary files
cleanup() {
    if [ -n "${TEMP_ARCHIVE:-}" ] && [ -f "${TEMP_ARCHIVE}" ]; then
        rm -f "${TEMP_ARCHIVE}"
    fi
    if [ -n "${TARGET_TEMP_ARCHIVE:-}" ] && [ -f "${TARGET_TEMP_ARCHIVE}" ]; then
        rm -f "${TARGET_TEMP_ARCHIVE}"
    fi
}
trap cleanup EXIT INT TERM

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Check arguments
if [ "$#" -ne 3 ]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    echo ""
    echo "Usage: $0 <from-url> <target-url> <database-name>"
    echo ""
    echo "Arguments:"
    echo "  from-url      - Source MongoDB URL (e.g., mongodb://source:27017)"
    echo "  target-url    - Target MongoDB URL (e.g., mongodb://localhost:27017)"
    echo "  database-name - Database name to migrate (e.g., mydatabase)"
    echo ""
    echo "Examples:"
    echo "  # Migrate database from source to local"
    echo "  $0 \"mongodb://source:27018\" \"mongodb://localhost:27018\" \"mydatabase\""
    exit 1
fi

FROM_URL="$1"
TARGET_URL="$2"
DATABASE_NAME="$3"

# Security validations
echo -e "${GREEN}=== MongoDB Database Migration ===${NC}"
echo -e "From: ${YELLOW}${FROM_URL}${NC}"
echo -e "To: ${YELLOW}${TARGET_URL}${NC}"
echo -e "Database: ${YELLOW}${DATABASE_NAME}${NC}"
echo ""

# Validate that source and target are different
if [ "$FROM_URL" = "$TARGET_URL" ]; then
    echo -e "${RED}Error: Source and target URLs cannot be the same!${NC}"
    echo "This would overwrite the source database."
    exit 1
fi

# Validate database name (prevent system database migration)
SYSTEM_DBS=("admin" "local" "config")
for sys_db in "${SYSTEM_DBS[@]}"; do
    if [ "$DATABASE_NAME" = "$sys_db" ]; then
        echo -e "${RED}Error: Cannot migrate system database '${sys_db}'${NC}"
        echo "This is a protected system database."
        exit 1
    fi
done

# Warn if target URL looks like production (contains common prod indicators)
if [[ "$TARGET_URL" =~ (prod|production|atlas|amazonaws|azure) ]]; then
    echo -e "${RED}⚠ WARNING: Target URL contains production-like keywords!${NC}"
    echo -e "${YELLOW}Target: ${TARGET_URL}${NC}"
    echo ""
    read -p "Are you sure you want to proceed? Type 'YES' to continue: " confirm_prod
    if [ "$confirm_prod" != "YES" ]; then
        echo "Migration cancelled for safety."
        exit 0
    fi
fi

# Check if mongodump and mongorestore are available
if ! command -v mongodump &> /dev/null; then
    echo -e "${RED}Error: mongodump not found${NC}"
    echo "Please install MongoDB Database Tools:"
    echo "  macOS: brew install mongodb-database-tools"
    echo "  Linux: https://www.mongodb.com/try/download/database-tools"
    exit 1
fi

if ! command -v mongorestore &> /dev/null; then
    echo -e "${RED}Error: mongorestore not found${NC}"
    echo "Please install MongoDB Database Tools:"
    echo "  macOS: brew install mongodb-database-tools"
    echo "  Linux: https://www.mongodb.com/try/download/database-tools"
    exit 1
fi

# Test source connection
echo -e "${YELLOW}Testing source connection...${NC}"
if ! mongosh "${FROM_URL}" --quiet --eval "db.adminCommand('ping')" &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to source MongoDB${NC}"
    echo "Please check the FROM_URL: ${FROM_URL}"
    exit 1
fi
echo -e "${GREEN}✓ Source connection OK${NC}"

# Test target connection
echo -e "${YELLOW}Testing target connection...${NC}"
if ! mongosh "${TARGET_URL}" --quiet --eval "db.adminCommand('ping')" &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to target MongoDB${NC}"
    echo "Please check the TARGET_URL: ${TARGET_URL}"
    echo "Make sure Docker containers are running: docker-compose ps"
    exit 1
fi
echo -e "${GREEN}✓ Target connection OK${NC}"

# Check if database exists on source
echo -e "${YELLOW}Checking if database exists on source...${NC}"
DB_EXISTS=$(mongosh "${FROM_URL}/${DATABASE_NAME}" --quiet --eval "db.getName()" 2>/dev/null || echo "")
if [ -z "$DB_EXISTS" ]; then
    echo -e "${RED}Error: Database '${DATABASE_NAME}' not found on source${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Database found on source${NC}"

# Get source database stats
echo -e "${YELLOW}Checking source database size...${NC}"
SOURCE_STATS=$(mongosh "${FROM_URL}/${DATABASE_NAME}" --quiet --eval "JSON.stringify(db.stats())" 2>/dev/null || echo "{}")
if [ -n "$SOURCE_STATS" ] && [ "$SOURCE_STATS" != "{}" ]; then
    SOURCE_SIZE=$(echo "$SOURCE_STATS" | grep -o '"dataSize"[^,]*' | grep -o '[0-9]*' || echo "0")
    if [ "$SOURCE_SIZE" != "0" ] && [ -n "$SOURCE_SIZE" ]; then
        SOURCE_SIZE_MB=$((SOURCE_SIZE / 1024 / 1024))
        echo -e "${GREEN}✓ Source database size: ~${SOURCE_SIZE_MB} MB${NC}"
        if [ "$SOURCE_SIZE_MB" -gt 1000 ]; then
            echo -e "${YELLOW}⚠ Large database detected (>1GB). Migration may take significant time.${NC}"
        fi
    fi
fi

# Check if database exists on target and warn about duplicates
echo -e "${YELLOW}Checking target database...${NC}"
TARGET_DB_EXISTS=$(mongosh "${TARGET_URL}/${DATABASE_NAME}" --quiet --eval "db.getName()" 2>/dev/null || echo "")
if [ -n "$TARGET_DB_EXISTS" ]; then
    TARGET_COLLECTIONS=$(mongosh "${TARGET_URL}/${DATABASE_NAME}" --quiet --eval "db.getCollectionNames().length" 2>/dev/null || echo "0")
    if [ "$TARGET_COLLECTIONS" != "0" ] && [ -n "$TARGET_COLLECTIONS" ]; then
        echo -e "${YELLOW}⚠ WARNING: Target database '${DATABASE_NAME}' already exists with ${TARGET_COLLECTIONS} collection(s)${NC}"
        echo -e "${YELLOW}⚠ Data will be ADDED to existing collections (duplicates may occur)${NC}"
        echo -e "${YELLOW}⚠ Documents with same _id will NOT be overwritten${NC}"
        echo ""
        read -p "Continue anyway? [y/N]: " confirm_existing
        if [[ ! "$confirm_existing" =~ ^[Yy]$ ]]; then
            echo "Migration cancelled"
            exit 0
        fi
    else
        echo -e "${GREEN}✓ Target database exists but is empty${NC}"
    fi
else
    echo -e "${GREEN}✓ Target database does not exist (will be created)${NC}"
fi

# Ask about backup first
echo ""
read -p "Create backup copies in scripts/backups? [y/N]: " create_backup
CREATE_BACKUP=false
FROM_BACKUP_ARCHIVE=""
TO_BACKUP_ARCHIVE=""
if [[ "$create_backup" =~ ^[Yy]$ ]]; then
    CREATE_BACKUP=true
    BACKUP_DIR="$(dirname "$0")/backups"
    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    FROM_BACKUP_ARCHIVE="${BACKUP_DIR}/from_${DATABASE_NAME}_${TIMESTAMP}.archive"
    TO_BACKUP_ARCHIVE="${BACKUP_DIR}/to_${DATABASE_NAME}_${TIMESTAMP}.archive"
    echo -e "${GREEN}Backups will be saved to:${NC}"
    echo -e "  Source: ${FROM_BACKUP_ARCHIVE}"
    echo -e "  Target: ${TO_BACKUP_ARCHIVE}"
fi

# Confirm before proceeding
echo ""
echo -e "${YELLOW}This will:${NC}"
echo "  1. Export all data from ${DATABASE_NAME} on ${FROM_URL}"
if [ "$CREATE_BACKUP" = true ]; then
    echo "  2. Create backup of source database"
    echo "  3. Import to ${DATABASE_NAME} on ${TARGET_URL}"
    echo "  4. Create backup of target database"
else
    echo "  2. Import to ${DATABASE_NAME} on ${TARGET_URL}"
fi
echo -e "${YELLOW}Note: Data will be added to existing collections (duplicates may occur)${NC}"
echo ""
read -p "Continue? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Migration cancelled"
    exit 0
fi

# Check available disk space
echo -e "${YELLOW}Checking available disk space...${NC}"
TMP_DIR="${TMPDIR:-/tmp}"
AVAILABLE_SPACE=$(df -m "$TMP_DIR" | tail -1 | awk '{print $4}')
if [ -n "$AVAILABLE_SPACE" ] && [ "$AVAILABLE_SPACE" -lt 1000 ]; then
    echo -e "${YELLOW}⚠ WARNING: Less than 1GB free space in ${TMP_DIR}${NC}"
    echo -e "${YELLOW}⚠ Migration may fail if database is large${NC}"
    echo ""
    read -p "Continue anyway? [y/N]: " confirm_space
    if [[ ! "$confirm_space" =~ ^[Yy]$ ]]; then
        echo "Migration cancelled"
        exit 0
    fi
else
    echo -e "${GREEN}✓ Sufficient disk space available (~${AVAILABLE_SPACE} MB)${NC}"
fi

# Perform migration
echo ""
echo -e "${GREEN}Starting migration...${NC}"
echo -e "${YELLOW}This may take a while depending on database size...${NC}"
echo ""

# Use temporary file method for better reliability with large databases
TEMP_ARCHIVE="${TMPDIR:-/tmp}/mongo-migrate-${DATABASE_NAME}-$(date +%s).archive"

echo -e "${YELLOW}Step 1/2: Exporting from source...${NC}"
EXPORT_ERROR=$(mongodump \
    --uri="${FROM_URL}" \
    --db="${DATABASE_NAME}" \
    --archive="${TEMP_ARCHIVE}" \
    2>&1)
EXPORT_EXIT_CODE=$?

if [ $EXPORT_EXIT_CODE -ne 0 ]; then
    echo -e "${RED}✗ Export failed${NC}"
    echo -e "${RED}Error details:${NC}"
    echo "$EXPORT_ERROR" | head -10
    exit 1
fi

# Verify archive was created and has content
if [ ! -f "${TEMP_ARCHIVE}" ] || [ ! -s "${TEMP_ARCHIVE}" ]; then
    echo -e "${RED}✗ Export failed: Archive file is empty or missing${NC}"
    exit 1
fi

ARCHIVE_SIZE=$(du -h "${TEMP_ARCHIVE}" | cut -f1)
echo -e "${GREEN}✓ Export completed (${ARCHIVE_SIZE})${NC}"

# Create backup of source database if requested
if [ "$CREATE_BACKUP" = true ]; then
    echo -e "${YELLOW}Creating backup of source database...${NC}"
    cp "${TEMP_ARCHIVE}" "${FROM_BACKUP_ARCHIVE}"
    if [ $? -eq 0 ]; then
        BACKUP_SIZE=$(du -h "${FROM_BACKUP_ARCHIVE}" | cut -f1)
        echo -e "${GREEN}✓ Source backup created: ${FROM_BACKUP_ARCHIVE} (${BACKUP_SIZE})${NC}"
    else
        echo -e "${YELLOW}⚠ Source backup creation failed, but continuing with migration...${NC}"
    fi
fi

echo -e "${YELLOW}Step 2/2: Importing to target...${NC}"
IMPORT_ERROR=$(mongorestore \
    --uri="${TARGET_URL}" \
    --db="${DATABASE_NAME}" \
    --archive="${TEMP_ARCHIVE}" \
    2>&1)
IMPORT_EXIT_CODE=$?

if [ $IMPORT_EXIT_CODE -ne 0 ]; then
    echo -e "${RED}✗ Import failed${NC}"
    echo -e "${RED}Error details:${NC}"
    echo "$IMPORT_ERROR" | head -10
    echo ""
    echo -e "${YELLOW}Note: Source database was NOT modified. You can retry the migration.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Import completed${NC}"

# Verify import by checking document counts (if possible)
echo -e "${YELLOW}Verifying import...${NC}"
SOURCE_COUNT=$(mongosh "${FROM_URL}/${DATABASE_NAME}" --quiet --eval "db.stats().collections" 2>/dev/null || echo "0")
TARGET_COUNT=$(mongosh "${TARGET_URL}/${DATABASE_NAME}" --quiet --eval "db.stats().collections" 2>/dev/null || echo "0")
if [ "$SOURCE_COUNT" != "0" ] && [ "$TARGET_COUNT" != "0" ]; then
    if [ "$TARGET_COUNT" -ge "$SOURCE_COUNT" ]; then
        echo -e "${GREEN}✓ Verification OK: ${TARGET_COUNT} collections in target (${SOURCE_COUNT} in source)${NC}"
    else
        echo -e "${YELLOW}⚠ Warning: Target has ${TARGET_COUNT} collections, source has ${SOURCE_COUNT}${NC}"
        echo -e "${YELLOW}⚠ Some collections may not have been imported${NC}"
    fi
fi

# Create backup of target database if requested
if [ "$CREATE_BACKUP" = true ]; then
    echo -e "${YELLOW}Creating backup of target database...${NC}"
    TARGET_TEMP_ARCHIVE="${TMPDIR:-/tmp}/mongo-backup-target-${DATABASE_NAME}-$(date +%s).archive"
    if mongodump \
        --uri="${TARGET_URL}" \
        --db="${DATABASE_NAME}" \
        --archive="${TARGET_TEMP_ARCHIVE}" \
        > /dev/null 2>&1; then
        cp "${TARGET_TEMP_ARCHIVE}" "${TO_BACKUP_ARCHIVE}"
        if [ $? -eq 0 ]; then
            BACKUP_SIZE=$(du -h "${TO_BACKUP_ARCHIVE}" | cut -f1)
            echo -e "${GREEN}✓ Target backup created: ${TO_BACKUP_ARCHIVE} (${BACKUP_SIZE})${NC}"
        else
            echo -e "${YELLOW}⚠ Target backup copy failed, but migration completed...${NC}"
        fi
        rm -f "${TARGET_TEMP_ARCHIVE}"
    else
        echo -e "${YELLOW}⚠ Target backup export failed, but migration completed...${NC}"
    fi
fi

echo ""
echo -e "${GREEN}✓ Migration completed successfully!${NC}"
echo ""
echo -e "Database ${DATABASE_NAME} is now available at: ${TARGET_URL}"
if [ "$CREATE_BACKUP" = true ]; then
    echo ""
    echo -e "${GREEN}Backups created:${NC}"
    echo -e "  Source: ${FROM_BACKUP_ARCHIVE}"
    echo -e "  Target: ${TO_BACKUP_ARCHIVE}"
fi
