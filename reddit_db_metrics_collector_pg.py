import os
import re
import time
import argparse
import asyncio
from dataclasses import dataclass
from typing import Dict, List, Optional, Set, Tuple

import asyncpg
import asyncpraw
from dotenv import load_dotenv

#load_dotenv()
#print(os.getenv("PG_DSN"))

# -----------------------------
# Platform taxonomy + matchers
# -----------------------------
# Text is only used in-memory for tagging;
PLATFORM_PATTERNS: Dict[str, List[str]] = {
    # RDBMS
    "PostgreSQL": [r"\bpostgres(?:ql)?\b", r"\bpg\b"],
    "SQL Server": [r"\bsql server\b", r"\bmssql\b", r"\bt-?sql\b"],
    "Oracle": [r"\boracle\b", r"\bpl\/sql\b", r"\bexadata\b", r"\bautonomous\b"],
    "MySQL": [r"\bmysql\b"],
    "MariaDB": [r"\bmariadb\b"],
    "SQLite": [r"\bsqlite\b"],
    "DB2": [r"\bdb2\b"],
    "CockroachDB": [r"\bcockroach(db)?\b"],
    "TiDB": [r"\btidb\b"],
    "SingleStore": [r"\bsinglestore\b", r"\bmemsql\b"],

    # Document / KV
    "MongoDB": [r"\bmongo(db)?\b"],
    "CouchDB": [r"\bcouchdb\b"],
    "DynamoDB": [r"\bdynamodb\b"],
    "Redis": [r"\bredis\b"],

    # Big data / analytics
    "Snowflake": [r"\bsnowflake\b"],
    "BigQuery": [r"\bbigquery\b"],
    "Redshift": [r"\bredshift\b"],
    "Databricks": [r"\bdatabricks\b", r"\bdelta lake\b", r"\bdelta\b"],
    "ClickHouse": [r"\bclickhouse\b"],
    "Hive": [r"\bhive\b"],
    "Impala": [r"\bimpala\b"],
    "Trino": [r"\btrino\b", r"\bpresto\b"],
    "Spark": [r"\bspark\b"],
    "Iceberg": [r"\biceberg\b"],

    # Enterprise / commercial
    "Teradata": [r"\bteradata\b"],
    "SAP HANA": [r"\bsap hana\b", r"\bhana\b"],
    "Vertica": [r"\bvertica\b"],
    "Netezza": [r"\bnetezza\b"],

    # Graph / other (optional)
    "Neo4j": [r"\bneo4j\b"],
    # NOTE: 'es' is noisy; keep only elasticsearch unless you want shorthand.
    "Elasticsearch": [r"\belasticsearch\b"],
}

# Cross-cutting "open-source" tag
OPEN_SOURCE_PLATFORMS: Set[str] = {
    "PostgreSQL", "MySQL", "MariaDB", "SQLite",
    "CockroachDB", "TiDB", "ClickHouse", "Hive", "Impala", "Trino", "Spark", "Iceberg",
    "CouchDB", "Redis", "Neo4j", "Elasticsearch",
}

DEFAULT_SUBREDDITS = [
    "Database", "dataengineering", "devops", "bigdata",
    "PostgreSQL", "SQLServer", "oracle", "mysql", "MongoDB",
    "snowflake", "databricks", "redis", "clickhouse"
]


def compile_patterns() -> Dict[str, List[re.Pattern]]:
    compiled: Dict[str, List[re.Pattern]] = {}
    for platform, patterns in PLATFORM_PATTERNS.items():
        compiled[platform] = [re.compile(pat, re.IGNORECASE) for pat in patterns]
    return compiled


COMPILED = compile_patterns()


def tag_platforms(text: str) -> List[str]:
    hits: List[str] = []
    if not text:
        return hits
    for platform, patterns in COMPILED.items():
        if any(p.search(text) for p in patterns):
            hits.append(platform)
    return hits


# -----------------------------
# Postgres schema
# -----------------------------
SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS submissions (
  submission_id TEXT PRIMARY KEY,
  created_utc   TIMESTAMPTZ NOT NULL,
  subreddit     TEXT NOT NULL,
  score         INTEGER,
  upvote_ratio  DOUBLE PRECISION,
  num_comments  INTEGER,
  retrieved_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS submission_platform (
  submission_id   TEXT NOT NULL REFERENCES submissions(submission_id) ON DELETE CASCADE,
  platform        TEXT NOT NULL,
  is_open_source  BOOLEAN NOT NULL,
  PRIMARY KEY (submission_id, platform)
);

CREATE TABLE IF NOT EXISTS submission_graph_metrics (
  submission_id           TEXT PRIMARY KEY REFERENCES submissions(submission_id) ON DELETE CASCADE,
  comment_count_observed  INTEGER NOT NULL,
  max_depth               INTEGER NOT NULL,
  branching_factor        DOUBLE PRECISION NOT NULL,
  reply_rate              DOUBLE PRECISION NOT NULL,
  retrieved_at            TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS submission_snapshots (
  submission_id  TEXT NOT NULL REFERENCES submissions(submission_id) ON DELETE CASCADE,
  retrieved_at   TIMESTAMPTZ NOT NULL,
  score          INTEGER,
  upvote_ratio   DOUBLE PRECISION,
  num_comments   INTEGER,
  PRIMARY KEY (submission_id, retrieved_at)
);

CREATE INDEX IF NOT EXISTS idx_submissions_created_utc ON submissions(created_utc);
CREATE INDEX IF NOT EXISTS idx_submissions_subreddit ON submissions(subreddit);
CREATE INDEX IF NOT EXISTS idx_subplat_platform ON submission_platform(platform);
"""


# -----------------------------
# Collector config
# -----------------------------
@dataclass
class CollectorConfig:
    pg_dsn: str
    subreddits: List[str]
    days_back: int
    per_subreddit_limit: int
    include_comment_graph: bool
    max_concurrent_submissions: int
    pool_min_size: int
    pool_max_size: int


def compute_comment_graph_metrics(parent_pairs: List[Tuple[str, Optional[str]]]) -> Tuple[int, int, float, float]:
    if not parent_pairs:
        return (0, 0, 0.0, 0.0)

    children: Dict[str, List[str]] = {}
    roots: List[str] = []
    parent_of: Dict[str, Optional[str]] = {}

    for cid, pid in parent_pairs:
        parent_of[cid] = pid
        if pid is None:
            roots.append(cid)
        else:
            children.setdefault(pid, []).append(cid)

    depth_cache: Dict[str, int] = {}

    def depth(cid: str) -> int:
        if cid in depth_cache:
            return depth_cache[cid]
        pid = parent_of.get(cid)
        if pid is None:
            depth_cache[cid] = 1
        else:
            depth_cache[cid] = 1 + depth(pid)
        return depth_cache[cid]

    depths = [depth(cid) for cid, _ in parent_pairs]
    max_depth = max(depths) if depths else 0

    branch_counts = [len(kids) for kids in children.values() if kids]
    branching_factor = float(sum(branch_counts) / len(branch_counts)) if branch_counts else 0.0

    replies_to_comment = sum(1 for _, pid in parent_pairs if pid is not None)
    reply_rate = float(replies_to_comment / len(parent_pairs)) if parent_pairs else 0.0

    return (len(parent_pairs), max_depth, branching_factor, reply_rate)


async def fetch_comment_graph(submission) -> Tuple[int, int, float, float]:
    await submission.load()
    await submission.comments.replace_more(limit=None)

    parent_pairs: List[Tuple[str, Optional[str]]] = []
    for c in submission.comments.list():
        pid_full = getattr(c, "parent_id", None)
        cid_full = getattr(c, "fullname", None)
        if not cid_full:
            continue

        cid = cid_full.split("_", 1)[-1]
        if pid_full and pid_full.startswith("t1_"):
            pid = pid_full.split("_", 1)[-1]
        else:
            pid = None

        parent_pairs.append((cid, pid))

    return compute_comment_graph_metrics(parent_pairs)


async def init_db(pool: asyncpg.Pool) -> None:
    async with pool.acquire() as conn:
        # You can set a specific schema if you want: SET search_path TO ...
        await conn.execute(SCHEMA_SQL)


UPSERT_SUBMISSION_SQL = """
INSERT INTO submissions(submission_id, created_utc, subreddit, score, upvote_ratio, num_comments, retrieved_at)
VALUES ($1, to_timestamp($2), $3, $4, $5, $6, now())
ON CONFLICT (submission_id) DO UPDATE SET
  score        = EXCLUDED.score,
  upvote_ratio = EXCLUDED.upvote_ratio,
  num_comments = EXCLUDED.num_comments,
  retrieved_at = now();
"""

INSERT_SNAPSHOT_SQL = """
INSERT INTO submission_snapshots(submission_id, retrieved_at, score, upvote_ratio, num_comments)
VALUES ($1, now(), $2, $3, $4)
ON CONFLICT DO NOTHING;
"""

INSERT_PLATFORM_SQL = """
INSERT INTO submission_platform(submission_id, platform, is_open_source)
VALUES ($1, $2, $3)
ON CONFLICT (submission_id, platform) DO NOTHING;
"""

UPSERT_GRAPH_SQL = """
INSERT INTO submission_graph_metrics(
  submission_id, comment_count_observed, max_depth, branching_factor, reply_rate, retrieved_at
)
VALUES ($1, $2, $3, $4, $5, now())
ON CONFLICT (submission_id) DO UPDATE SET
  comment_count_observed = EXCLUDED.comment_count_observed,
  max_depth              = EXCLUDED.max_depth,
  branching_factor       = EXCLUDED.branching_factor,
  reply_rate             = EXCLUDED.reply_rate,
  retrieved_at           = now();
"""


async def process_submission(
    sem: asyncio.Semaphore,
    pool: asyncpg.Pool,
    submission,
    include_comment_graph: bool,
) -> None:
    async with sem:
        # In-memory text for tagging only; never stored.
        title = getattr(submission, "title", "") or ""
        selftext = getattr(submission, "selftext", "") or ""
        platforms = tag_platforms(f"{title}\n{selftext}")

        # Skip non-database threads (keeps dataset focused)
        if not platforms:
            return

        submission_id = submission.id
        created_utc = int(submission.created_utc)
        subreddit = str(submission.subreddit.display_name)
        score = int(getattr(submission, "score", 0) or 0)
        upvote_ratio = getattr(submission, "upvote_ratio", None)
        num_comments = int(getattr(submission, "num_comments", 0) or 0)

        # Write metrics (one connection)
        async with pool.acquire() as conn:
            async with conn.transaction():
                await conn.execute(
                    UPSERT_SUBMISSION_SQL,
                    submission_id, created_utc, subreddit, score, upvote_ratio, num_comments
                )
                await conn.execute(
                    INSERT_SNAPSHOT_SQL,
                    submission_id, score, upvote_ratio, num_comments
                )

                for platform in platforms:
                    is_os = platform in OPEN_SOURCE_PLATFORMS
                    await conn.execute(INSERT_PLATFORM_SQL, submission_id, platform, is_os)

        if include_comment_graph:
            try:
                cc, max_depth, bf, rr = await fetch_comment_graph(submission)
            except Exception:
                # Keep resilient: record zeros if graph fails
                cc, max_depth, bf, rr = 0, 0, 0.0, 0.0

            async with pool.acquire() as conn:
                await conn.execute(UPSERT_GRAPH_SQL, submission_id, cc, max_depth, bf, rr)


async def collect(config: CollectorConfig) -> None:
    load_dotenv()

    if not config.pg_dsn:
        raise SystemExit("Missing PG_DSN in env/.env or --pg-dsn argument.")
    client_id = os.getenv("REDDIT_CLIENT_ID")
    client_secret = os.getenv("REDDIT_CLIENT_SECRET")
    user_agent = os.getenv("REDDIT_USER_AGENT")

    if not client_id or not client_secret or not user_agent:
        raise SystemExit("Missing Reddit creds. Set REDDIT_CLIENT_ID, REDDIT_CLIENT_SECRET, REDDIT_USER_AGENT.")

    pool = await asyncpg.create_pool(
        dsn=config.pg_dsn,
        min_size=config.pool_min_size,
        max_size=config.pool_max_size,
        command_timeout=60,
    )

    await init_db(pool)

    reddit = asyncpraw.Reddit(
        client_id=client_id,
        client_secret=client_secret,
        user_agent=user_agent,
    )

    cutoff_epoch = int(time.time()) - int(config.days_back * 86400)
    sem = asyncio.Semaphore(config.max_concurrent_submissions)

    tasks: List[asyncio.Task] = []

    try:
        for sr in config.subreddits:
            subreddit = await reddit.subreddit(sr)
            queued = 0
            async for submission in subreddit.new(limit=config.per_subreddit_limit):
                if int(submission.created_utc) < cutoff_epoch:
                    break
                tasks.append(
                    asyncio.create_task(
                        process_submission(sem, pool, submission, config.include_comment_graph)
                    )
                )
                queued += 1
            print(f"[{sr}] queued {queued} submissions (days_back={config.days_back})")

        if tasks:
            await asyncio.gather(*tasks)
        else:
            print("No submissions found in the given window.")

    finally:
        await reddit.close()
        await pool.close()


def parse_args() -> CollectorConfig:
    p = argparse.ArgumentParser(description="Reddit DB metrics collector (numbers-only) -> Postgres.")
    p.add_argument("--pg-dsn", default=os.getenv("PG_DSN", ""), help="Postgres DSN (or set PG_DSN env var)")
    p.add_argument("--subreddits", default=",".join(DEFAULT_SUBREDDITS), help="Comma-separated subreddit list")
    p.add_argument("--days-back", type=int, default=7, help="How many days back to ingest")
    p.add_argument("--per-subreddit-limit", type=int, default=200, help="Max submissions to scan per subreddit")
    p.add_argument("--include-comment-graph", action="store_true", help="Compute depth/branch/reply-rate (heavier)")
    p.add_argument("--max-concurrency", type=int, default=10, help="Max concurrent submission processors")
    p.add_argument("--pool-min", type=int, default=1, help="DB pool min size")
    p.add_argument("--pool-max", type=int, default=5, help="DB pool max size")
    args = p.parse_args()

    return CollectorConfig(
        pg_dsn=args.pg_dsn,
        subreddits=[s.strip() for s in args.subreddits.split(",") if s.strip()],
        days_back=args.days_back,
        per_subreddit_limit=args.per_subreddit_limit,
        include_comment_graph=args.include_comment_graph,
        max_concurrent_submissions=args.max_concurrency,
        pool_min_size=args.pool_min,
        pool_max_size=args.pool_max,
    )


if __name__ == "__main__":
    cfg = parse_args()
    asyncio.run(collect(cfg))
