import os
import pytest
from dotenv import load_dotenv
from sqlalchemy import create_engine, text

# Load environment variables from .env file
load_dotenv()

def get_db_url():
    host = os.getenv("DB_HOST", "localhost")
    port = os.getenv("DB_PORT", "5432")
    name = os.getenv("DB_NAME", "rtt_db")
    user = os.getenv("DB_USER", "postgres")
    password = os.getenv("DB_PASSWORD", "postgres")
    
    return f"postgresql://{user}:{password}@{host}:{port}/{name}"

def test_db_connection():
    """Verify that we can establish a connection to the PostgreSQL database."""
    db_url = get_db_url()
    engine = create_engine(db_url)
    
    with engine.connect() as conn:
        result = conn.execute(text("SELECT 1;"))
        assert result.fetchone()[0] == 1

def test_schemas_exist():
    """Verify that the raw, staging, and marts schemas were successfully created."""
    db_url = get_db_url()
    engine = create_engine(db_url)
    
    with engine.connect() as conn:
        result = conn.execute(text("""
            SELECT schema_name 
            FROM information_schema.schemata 
            WHERE schema_name IN ('raw', 'staging', 'marts');
        """))
        schemas = [row[0] for row in result.fetchall()]
        
        assert "raw" in schemas, "raw schema not found"
        assert "staging" in schemas, "staging schema not found"
        assert "marts" in schemas, "marts schema not found"
