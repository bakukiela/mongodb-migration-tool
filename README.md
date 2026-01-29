# MongoDB Migration Tool

Simple script to migrate MongoDB database from one server to another. Uses mongodump and mongorestore tools for safe data transfer.

## Problem it solves

This script was created to solve a problem where when working with databases in Docker or other containerization tools, the database is usually empty after startup. Once we fill it with data, after stopping the container the data is removed, because containers typically don't have persistent data storage. This makes testing and application development difficult, as you need to manually fill the database with test data every time.

This script enables quick and efficient data import from an existing source database to a local container, which significantly facilitates testing and development work.

## Requirements

Before using, make sure you have MongoDB Database Tools installed:

- macOS: `brew install mongodb-database-tools`
- Linux: download from [MongoDB official website](https://www.mongodb.com/try/download/database-tools)

The script also requires access to both databases - source and target.

## How to run

1. Make sure the script has execute permissions:
   ```bash
   chmod +x migrate-database.sh
   ```

2. Run the script with three arguments:
   ```bash
   ./migrate-database.sh <from-url> <target-url> <database-name>
   ```

The script will guide you through the migration process with interactive prompts.

## Usage

```bash
./migrate-database.sh <from-url> <target-url> <database-name>
```

### Parameters

- `from-url` - source MongoDB address (e.g., `mongodb://source:27017`)
- `target-url` - target MongoDB address (e.g., `mongodb://localhost:27017`)
- `database-name` - database name to migrate (e.g., `myDataBaseName`)

### Examples

Migrating database from source server to local Docker:

```bash
./migrate-database.sh "mongodb://source:27017" "mongodb://localhost:27017" "mydatabase"
```

## What the script does

1. Checks connections to both databases
2. Verifies that the source database exists
3. Warns if the target database already exists (data will be added, duplicates may occur)
4. Asks about creating backups (optional)
5. Exports data from the source database
6. Imports data to the target database
7. Verifies migration correctness

## Security features

The script includes several security measures:

- Prevents migration of system databases (admin, local, config)
- Prevents using the same address as source and target
- Warns if the target address looks like production
- Checks available disk space before starting migration
- Asks for confirmation before performing operations

## Backups

During migration you can choose to create backups. They will be saved in the `backups/` directory next to the script. Backups contain full export of both the source database and the target database after migration.

## Notes

- If the target database already exists, data will be added to existing collections. Documents with the same `_id` will not be overwritten.
- Migration of large databases may take a significant amount of time.
- Make sure you have enough disk space in the temporary directory.
