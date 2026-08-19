import os
import re
from pathlib import Path
import psycopg2
from dotenv import load_dotenv

# Load environment variables from .env
load_dotenv()

def get_connection():
    """Establish and return a connection to the PostgreSQL database."""
    host = os.getenv("DB_HOST", "localhost")
    port = os.getenv("DB_PORT", "5432")
    dbname = os.getenv("DB_NAME", "rtt_db")
    user = os.getenv("DB_USER", "postgres")
    password = os.getenv("DB_PASSWORD", "postgres")
    
    return psycopg2.connect(
        host=host,
        port=port,
        dbname=dbname,
        user=user,
        password=password
    )

def run_migrations():
    """Discover and execute all SQL migrations under the sql/ folder in numeric order."""
    project_root = Path(__file__).resolve().parents[1]
    sql_dir = project_root / "sql"
    
    # Recursively find all SQL files
    sql_files = list(sql_dir.glob("**/*.sql"))
    
    def migration_sort_key(path: Path) -> int:
        # Extract the leading numeric prefix from the filename (e.g. '00_init.sql' -> 0)
        match = re.match(r"^(\d+)", path.name)
        if match:
            return int(match.group(1))
        # Fallback to a high value if no numeric prefix exists
        return 9999

    sorted_files = sorted(sql_files, key=migration_sort_key)
    
    conn = get_connection()
    try:
        with conn:
            with conn.cursor() as cur:
                for file_path in sorted_files:
                    rel_path = file_path.relative_to(project_root)
                    print(f"Executing migration: {rel_path}")
                    with open(file_path, "r", encoding="utf-8") as f:
                        sql_content = f.read()
                        if sql_content.strip():
                            cur.execute(sql_content)
        print("All migrations completed successfully.")
    except Exception as e:
        failed_file = file_path.name if 'file_path' in locals() else 'unknown'
        print(f"Migration failed on file {failed_file}: {e}")
        conn.rollback()
        raise e
    finally:
        conn.close()

if __name__ == "__main__":
    run_migrations()
