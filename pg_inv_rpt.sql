\set ON_ERROR_STOP on
\pset pager off
\pset border 2
\pset linestyle unicode
\pset null '(null)'
\pset format aligned
\timing off

-- =========================
-- Postgres Database Inventory Script
-- Author:  Kellyn Gorman
-- Collects Basic Info about a specific Postgres DB
-- Prompt for inputs
-- Expects PGHOST/PGPORT/etc. already set in environment
-- Usage: \i C:/path_to_file/pg_inv_rpt.sql
-- =========================
\qecho
\qecho ============================================================
\qecho PostgreSQL Database Inventory Report
\qecho - Prompts for user and database
\qecho - Usage: Log in with psql to cluster, run script- 
\qecho ============================================================
\qecho

\prompt 'Login user (PGUSER): ' rpt_user
\prompt 'Target database (PGDATABASE): ' rpt_db

-- Apply to this psql session
\setenv PGUSER :rpt_user
\setenv PGDATABASE :rpt_db

-- Reconnect using the env vars (PGHOST/PGPORT should already be set outside)
\c

-- =========================
-- Output file
-- =========================
SELECT to_char(CURRENT_DATE, 'MMDDYYYY') AS report_date \gset

\set report_file 'pg_report_':rpt_db'_':report_date'.txt'
\o :report_file

\qecho ============================================================
\qecho PostgreSQL Database Report
\qecho Report created on :report_date
\qecho Target: User=:rpt_user  Database=:rpt_db
\qecho ============================================================

-- ----------------------------------------------------------------
\qecho
\qecho 1) Basic Database Information
\qecho ----------------------------------------------------------------
SELECT
  current_database()                    AS database_name,
  current_setting('server_version')     AS server_version,
  current_setting('server_version_num') AS server_version_num,
  pg_is_in_recovery()                   AS is_in_recovery;

\qecho
\qecho Server build / OS information (from version()):
SELECT version();

-- ----------------------------------------------------------------
\qecho
\qecho 1.2) Extensions Inventory (Cluster vs Database)
\qecho ----------------------------------------------------------------

\qecho
\qecho 1.3 Cluster-level: Available extensions (installed on the server)
\qecho Note: "installed_version" is null when the extension is not installed in this database.
SELECT
  name,
  default_version,
  installed_version,
  comment
FROM pg_available_extensions
ORDER BY name;

\qecho
\qecho 1.4 Database-level: Extensions enabled in this database
SELECT
  n.nspname AS schema_name,
  e.extname AS extension_name,
  e.extversion AS installed_version,
  pg_get_userbyid(e.extowner) AS owner
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
ORDER BY e.extname;

\qecho
\qecho 1.5 Database-level: Enabled extensions with their objects count (quick footprint)
\qecho Note: This is a rough indicator of how much an extension adds to the catalog.
SELECT
  e.extname AS extension_name,
  e.extversion AS installed_version,
  COUNT(d.objid) AS object_count
FROM pg_extension e
LEFT JOIN pg_depend d
  ON d.refclassid = 'pg_extension'::regclass
 AND d.refobjid   = e.oid
GROUP BY e.extname, e.extversion
ORDER BY object_count DESC, e.extname;

\qecho
\qecho 1.6 Cluster-level: Available extensions NOT enabled in this database
SELECT
  a.name,
  a.default_version,
  a.comment
FROM pg_available_extensions a
LEFT JOIN pg_extension e
  ON e.extname = a.name
WHERE e.extname IS NULL
ORDER BY a.name;

-- ----------------------------------------------------------------
\qecho
\qecho 2) Database and Cluster Size
\qecho ----------------------------------------------------------------
SELECT
  current_database() AS scope,
  pg_size_pretty(pg_database_size(current_database())) AS size_pretty,
  pg_database_size(current_database()) AS size_bytes;

SELECT
  'cluster_total' AS scope,
  pg_size_pretty(SUM(pg_database_size(datname))) AS size_pretty,
  SUM(pg_database_size(datname)) AS size_bytes
FROM pg_database;

-- ----------------------------------------------------------------
\qecho
\qecho 3) Schemas
\qecho ----------------------------------------------------------------
SELECT
  nspname AS schema_name,
  pg_get_userbyid(nspowner) AS owner
FROM pg_namespace
WHERE nspname NOT IN ('pg_catalog','information_schema')
  AND nspname NOT LIKE 'pg_toast%'
  AND nspname NOT LIKE 'pg_temp_%'
ORDER BY nspname;

-- ----------------------------------------------------------------
\qecho
\qecho 4) Default Tablespaces
\qecho ----------------------------------------------------------------
\qecho Role default tablespaces (login roles):
SELECT
  r.rolname AS role_name,
  COALESCE(t.spcname, '(default)') AS default_tablespace
FROM pg_roles r
LEFT JOIN pg_tablespace t ON t.oid = r.oid
WHERE r.rolcanlogin
ORDER BY r.rolname;

\qecho
\qecho Database default tablespace:
SELECT
  d.datname AS database_name,
  COALESCE(t.spcname, '(default)') AS default_tablespace
FROM pg_database d
LEFT JOIN pg_tablespace t ON t.oid = d.dattablespace
WHERE d.datname = current_database();

-- ----------------------------------------------------------------
\qecho
\qecho 5) Per-Schema Size (tables + indexes + toast, etc.)
\qecho ----------------------------------------------------------------
WITH user_schemas AS (
  SELECT oid, nspname
  FROM pg_namespace
  WHERE nspname NOT IN ('pg_catalog','information_schema')
    AND nspname NOT LIKE 'pg_toast%'
    AND nspname NOT LIKE 'pg_temp_%'
),
schema_rels AS (
  -- Ordinary tables, partitioned tables, matviews, indexes, sequences, toast, etc.
  SELECT c.oid, c.relnamespace
  FROM pg_class c
  JOIN user_schemas s ON s.oid = c.relnamespace
  WHERE c.relkind IN ('r','p','m','i','S','t')  -- include toast 't' where visible
)
SELECT
  s.nspname AS schema_name,
  pg_size_pretty(SUM(pg_total_relation_size(r.oid))) AS total_size_pretty,
  SUM(pg_total_relation_size(r.oid)) AS total_size_bytes
FROM user_schemas s
LEFT JOIN schema_rels r ON r.relnamespace = s.oid
GROUP BY s.nspname
ORDER BY SUM(pg_total_relation_size(r.oid)) DESC NULLS LAST, s.nspname;

-- ----------------------------------------------------------------
\qecho
\qecho 6) Object Counts by Schema and Type
\qecho ----------------------------------------------------------------
WITH schemas AS (
  SELECT oid, nspname
  FROM pg_namespace
  WHERE nspname NOT IN ('pg_catalog', 'information_schema')
    AND nspname NOT LIKE 'pg_toast%'
    AND nspname NOT LIKE 'pg_temp_%'
)
SELECT
  s.nspname AS schema_name,
  c.relkind AS object_type_code,
  COUNT(*)  AS object_count
FROM schemas s
JOIN pg_class c ON c.relnamespace = s.oid
GROUP BY s.nspname, c.relkind
ORDER BY s.nspname, c.relkind;

\qecho
\qecho Object type codes:
\qecho r=table, p=partitioned table, i=index, S=sequence
\qecho v=view, m=materialized view, t=TOAST table, c=composite type

-- ----------------------------------------------------------------
\qecho
\qecho 7) Tablespace Usage Per Object (tables, indexes, matviews, sequences, toast)
\qecho ----------------------------------------------------------------
\qecho Notes:
\qecho - If reltablespace=0 then it inherits the database default tablespace
\qecho - Toast tables/indexes may appear depending on visibility/privileges

WITH db_default AS (
  SELECT dattablespace
  FROM pg_database
  WHERE datname = current_database()
),
rels AS (
  SELECT
    n.nspname AS schema_name,
    c.relname AS object_name,
    c.relkind AS object_type_code,
    c.oid     AS object_oid,
    CASE
      WHEN c.reltablespace <> 0 THEN c.reltablespace
      ELSE (SELECT dattablespace FROM db_default)
    END AS effective_tablespace_oid
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    AND n.nspname NOT LIKE 'pg_toast%'
    AND n.nspname NOT LIKE 'pg_temp_%'
    AND c.relkind IN ('r','p','i','m','S','t')
)
SELECT
  r.schema_name,
  r.object_name,
  r.object_type_code,
  COALESCE(t.spcname, '(default)') AS tablespace_name,
  pg_size_pretty(pg_total_relation_size(r.object_oid)) AS total_size_pretty,
  pg_total_relation_size(r.object_oid) AS total_size_bytes
FROM rels r
LEFT JOIN pg_tablespace t ON t.oid = r.effective_tablespace_oid
ORDER BY
  r.schema_name,
  tablespace_name,
  pg_total_relation_size(r.object_oid) DESC,
  r.object_name;

-- ----------------------------------------------------------------
\qecho
\qecho 8) Partitioning Inventory
\qecho ----------------------------------------------------------------

\qecho
\qecho 8.1 Partitioned parent tables (strategy, key, partition count)
WITH parents AS (
  SELECT
    n.nspname AS parent_schema,
    c.relname AS parent_table,
    c.oid     AS parent_oid
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'p'  -- partitioned table
    AND n.nspname NOT IN ('pg_catalog','information_schema')
    AND n.nspname NOT LIKE 'pg_toast%'
    AND n.nspname NOT LIKE 'pg_temp_%'
),
pkey AS (
  SELECT
    p.parent_oid,
    pg_get_partkeydef(p.parent_oid) AS partition_key
  FROM parents p
),
pstrat AS (
  SELECT
    p.parent_oid,
    CASE pt.partstrat
      WHEN 'r' THEN 'RANGE'
      WHEN 'l' THEN 'LIST'
      WHEN 'h' THEN 'HASH'
      ELSE pt.partstrat::text
    END AS partition_strategy
  FROM parents p
  JOIN pg_partitioned_table pt ON pt.partrelid = p.parent_oid
),
pcounts AS (
  SELECT
    p.parent_oid,
    COUNT(i.inhrelid) AS partition_count
  FROM parents p
  LEFT JOIN pg_inherits i ON i.inhparent = p.parent_oid
  GROUP BY p.parent_oid
)
SELECT
  p.parent_schema,
  p.parent_table,
  s.partition_strategy,
  k.partition_key,
  c.partition_count
FROM parents p
JOIN pstrat  s ON s.parent_oid = p.parent_oid
JOIN pkey    k ON k.parent_oid = p.parent_oid
JOIN pcounts c ON c.parent_oid = p.parent_oid
ORDER BY p.parent_schema, p.parent_table;

\qecho
\qecho 8.2 Partition details (bounds, tablespace, size)
\qecho Note: size columns may show permission errors if you lack access.
WITH db_default AS (
  SELECT dattablespace
  FROM pg_database
  WHERE datname = current_database()
),
parts AS (
  SELECT
    pn.nspname AS parent_schema,
    pc.relname AS parent_table,
    pc.oid     AS parent_oid,
    cn.nspname AS partition_schema,
    cc.relname AS partition_table,
    cc.oid     AS partition_oid,
    CASE
      WHEN cc.reltablespace <> 0 THEN cc.reltablespace
      ELSE (SELECT dattablespace FROM db_default)
    END AS effective_tablespace_oid
  FROM pg_inherits i
  JOIN pg_class pc      ON pc.oid = i.inhparent
  JOIN pg_namespace pn  ON pn.oid = pc.relnamespace
  JOIN pg_class cc      ON cc.oid = i.inhrelid
  JOIN pg_namespace cn  ON cn.oid = cc.relnamespace
  WHERE pc.relkind = 'p'
    AND pn.nspname NOT IN ('pg_catalog','information_schema')
    AND pn.nspname NOT LIKE 'pg_toast%'
    AND pn.nspname NOT LIKE 'pg_temp_%'
)
SELECT
  parent_schema,
  parent_table,
  partition_schema,
  partition_table,
  pg_get_expr(c.relpartbound, c.oid) AS partition_bound,
  COALESCE(t.spcname, '(default)') AS tablespace_name,
  pg_size_pretty(pg_total_relation_size(partition_oid)) AS total_size_pretty,
  pg_total_relation_size(partition_oid) AS total_size_bytes
FROM parts
JOIN pg_class c ON c.oid = parts.partition_oid
LEFT JOIN pg_tablespace t ON t.oid = parts.effective_tablespace_oid
ORDER BY
  parent_schema, parent_table, partition_schema, partition_table;

\qecho
\qecho 8.3 Partitioning summary (partitions and total size per parent)
WITH parents AS (
  SELECT
    pn.nspname AS parent_schema,
    pc.relname AS parent_table,
    pc.oid     AS parent_oid
  FROM pg_class pc
  JOIN pg_namespace pn ON pn.oid = pc.relnamespace
  WHERE pc.relkind = 'p'
    AND pn.nspname NOT IN ('pg_catalog','information_schema')
    AND pn.nspname NOT LIKE 'pg_toast%'
    AND pn.nspname NOT LIKE 'pg_temp_%'
),
children AS (
  SELECT
    p.parent_oid,
    cc.oid AS partition_oid
  FROM parents p
  JOIN pg_inherits i ON i.inhparent = p.parent_oid
  JOIN pg_class cc   ON cc.oid = i.inhrelid
)
SELECT
  p.parent_schema,
  p.parent_table,
  COUNT(c.partition_oid) AS partition_count,
  pg_size_pretty(SUM(pg_total_relation_size(c.partition_oid))) AS partitions_total_size_pretty,
  SUM(pg_total_relation_size(c.partition_oid)) AS partitions_total_size_bytes
FROM parents p
LEFT JOIN children c ON c.parent_oid = p.parent_oid
GROUP BY p.parent_schema, p.parent_table
ORDER BY SUM(pg_total_relation_size(c.partition_oid)) DESC NULLS LAST,
         p.parent_schema, p.parent_table;


-- ----------------------------------------------------------------
\qecho
\qecho 9) Row Level Security (RLS) Inventory
\qecho ----------------------------------------------------------------

\qecho
\qecho 9.1 Tables with RLS enabled / forced
SELECT
  n.nspname AS schema_name,
  c.relname AS table_name,
  CASE WHEN c.relrowsecurity THEN 'ENABLED' ELSE 'disabled' END AS rls_status,
  CASE WHEN c.relforcerowsecurity THEN 'FORCED' ELSE 'not forced' END AS rls_enforcement,
  pg_get_userbyid(c.relowner) AS table_owner
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p') -- ordinary and partitioned tables
  AND (c.relrowsecurity OR c.relforcerowsecurity)
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
  AND n.nspname NOT LIKE 'pg_temp_%'
ORDER BY n.nspname, c.relname;

\qecho
\qecho 9.2 RLS policies (policy details per table)
\qecho Note: USING / WITH CHECK expressions are shown as SQL text.
SELECT
  schemaname AS schema_name,
  tablename  AS table_name,
  policyname AS policy_name,
  CASE permissive
    WHEN 'PERMISSIVE' THEN 'PERMISSIVE'
    WHEN 'RESTRICTIVE' THEN 'RESTRICTIVE'
    ELSE permissive
  END AS policy_mode,
  cmd AS command,
  roles AS applied_to_roles,
  qual AS using_expression,
  with_check AS with_check_expression
FROM pg_policies
WHERE schemaname NOT IN ('pg_catalog','information_schema')
ORDER BY schemaname, tablename, policyname;

\qecho
\qecho 9.3 Roles that can BYPASS RLS (rolbypassrls=true)
SELECT
  r.rolname AS role_name,
  r.rolsuper AS is_superuser,
  r.rolbypassrls AS bypass_rls
FROM pg_roles r
WHERE r.rolbypassrls = true OR r.rolsuper = true
ORDER BY r.rolsuper DESC, r.rolbypassrls DESC, r.rolname;

\qecho
\qecho 9.4 RLS coverage summary (counts by schema)
WITH rls_tables AS (
  SELECT n.nspname AS schema_name
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r','p')
    AND (c.relrowsecurity OR c.relforcerowsecurity)
    AND n.nspname NOT IN ('pg_catalog','information_schema')
    AND n.nspname NOT LIKE 'pg_toast%'
    AND n.nspname NOT LIKE 'pg_temp_%'
),
all_tables AS (
  SELECT n.nspname AS schema_name
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r','p')
    AND n.nspname NOT IN ('pg_catalog','information_schema')
    AND n.nspname NOT LIKE 'pg_toast%'
    AND n.nspname NOT LIKE 'pg_temp_%'
)
SELECT
  a.schema_name,
  COUNT(*) AS total_tables,
  COALESCE(SUM(CASE WHEN r.schema_name IS NOT NULL THEN 1 ELSE 0 END), 0) AS rls_tables,
  ROUND(
    (COALESCE(SUM(CASE WHEN r.schema_name IS NOT NULL THEN 1 ELSE 0 END), 0)::numeric
     / NULLIF(COUNT(*), 0)) * 100,
    2
  ) AS rls_percent
FROM all_tables a
LEFT JOIN rls_tables r ON r.schema_name = a.schema_name
GROUP BY a.schema_name
ORDER BY rls_tables DESC, a.schema_name;

-- ----------------------------------------------------------------
\qecho
\qecho End of report
\qecho ============================================================

-- Notes: Additions- sequences, functions, extensions
-- Along with version, what about compatibility/flavor?
-- Collation, shared/preloaded libraries
\o
\qecho Report written to: :report_file
