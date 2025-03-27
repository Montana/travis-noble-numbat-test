#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

DB_NAME="test"
DB_USER="postgres"

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}PostgreSQL Database Monitoring Tool${NC}"
echo -e "${BLUE}=========================================${NC}"
echo "Started at $(date)"
echo ""

if ! pgrep -x "postgres" > /dev/null; then
    echo -e "${RED}ERROR: PostgreSQL is not running${NC}"
    exit 1
fi

echo -e "${BLUE}PostgreSQL Version:${NC}"
psql -d $DB_NAME -U $DB_USER -c "SELECT version();" | grep PostgreSQL
echo ""

echo -e "${BLUE}Database Size:${NC}"
psql -d $DB_NAME -U $DB_USER -c "SELECT pg_size_pretty(pg_database_size('$DB_NAME')) as database_size;"
echo ""

echo -e "${BLUE}Table Sizes:${NC}"
psql -d $DB_NAME -U $DB_USER -c "SELECT 
    table_name, 
    pg_size_pretty(pg_total_relation_size(quote_ident(table_name))) as total_size,
    pg_size_pretty(pg_relation_size(quote_ident(table_name))) as table_size,
    pg_size_pretty(pg_total_relation_size(quote_ident(table_name)) - pg_relation_size(quote_ident(table_name))) as index_size
FROM (
    SELECT table_name 
    FROM information_schema.tables 
    WHERE table_schema = 'public'
    AND table_type = 'BASE TABLE'
) as tables
ORDER BY pg_total_relation_size(quote_ident(table_name)) DESC
LIMIT 5;"
echo ""

echo -e "${BLUE}Inactive Users (No login in last 7 days):${NC}"
psql -d $DB_NAME -U $DB_USER -c "SELECT username, email, 
    EXTRACT(DAY FROM (CURRENT_TIMESTAMP - last_login)) as days_since_login
FROM users
WHERE EXTRACT(DAY FROM (CURRENT_TIMESTAMP - last_login)) > 7
AND is_active = true
ORDER BY days_since_login DESC
LIMIT 10;"
echo ""

echo -e "${BLUE}Recent User Activity (Last 24 hours):${NC}"
psql -d $DB_NAME -U $DB_USER -c "SELECT u.username, 
    a.activity_type, 
    a.created_at, 
    a.ip_address
FROM user_activity a
JOIN users u ON a.user_id = u.id
WHERE a.created_at > CURRENT_TIMESTAMP - INTERVAL '24 hours'
ORDER BY a.created_at DESC
LIMIT 15;"
echo ""

echo -e "${BLUE}Current Database Connections:${NC}"
psql -d $DB_NAME -U $DB_USER -c "SELECT 
    datname as database, 
    usename as username, 
    application_name, 
    client_addr, 
    state, 
    EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - state_change)) as seconds_in_state
FROM pg_stat_activity
WHERE datname = '$DB_NAME'
ORDER BY seconds_in_state DESC;"
echo ""

echo -e "${BLUE}Slow Queries Analysis:${NC}"
psql -d $DB_NAME -U $DB_USER -c "SELECT 
    substring(query, 1, 50) as short_query,
    round(total_exec_time::numeric, 2) as total_time_ms,
    calls,
    round(mean_exec_time::numeric, 2) as mean_time_ms,
    round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 2) as percentage_cpu
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 5;"
echo ""

echo -e "${BLUE}Database Health Check:${NC}"
psql -d $DB_NAME -U $DB_USER -c "WITH bloat_info AS (
    SELECT
        schemaname, tablename,
        ROUND(CASE WHEN otta=0 THEN 0.0 ELSE sml.relpages/otta::numeric END,1) AS tbloat,
        CASE WHEN relpages < otta THEN 0 ELSE bs*(sml.relpages-otta)::bigint END AS wastedbytes
    FROM (
        SELECT
            schemaname, tablename, cc.reltuples, cc.relpages, bs,
            CEIL((cc.reltuples*((datahdr+ma-
                (CASE WHEN datahdr%ma=0 THEN ma ELSE datahdr%ma END))+nullhdr2+4))/(bs-20::float)) AS otta
        FROM (
            SELECT
                ma,bs,schemaname,tablename,
                (datawidth+(hdr+ma-(CASE WHEN hdr%ma=0 THEN ma ELSE hdr%ma END)))::numeric AS datahdr,
                (maxfracsum*(nullhdr+ma-(CASE WHEN nullhdr%ma=0 THEN ma ELSE nullhdr%ma END))) AS nullhdr2
            FROM (
                SELECT
                    schemaname, tablename, hdr, ma, bs,
                    SUM((1-null_frac)*avg_width) AS datawidth,
                    MAX(null_frac) AS maxfracsum,
                    hdr+(
                        SELECT 1+COUNT(*)/8
                        FROM pg_stats s2
                        WHERE null_frac<>0 AND s2.schemaname = s.schemaname AND s2.tablename = s.tablename
                    ) AS nullhdr
                FROM pg_stats s, (
                    SELECT
                        (SELECT current_setting('block_size')::numeric) AS bs,
                        CASE WHEN SUBSTRING(SPLIT_PART(v, ' ', 2) FROM '#\"[0-9]+.[0-9]+#\"%' for '#')
                          IS NULL THEN 8 ELSE 4 END AS hdr,
                        CASE WHEN v ~ 'mingw32' OR v ~ '64-bit' THEN 8 ELSE 4 END AS ma
                    FROM (SELECT version() AS v) AS foo
                ) AS constants
                GROUP BY 1,2,3,4,5
            ) AS foo
        ) AS foo
        JOIN pg_class cc ON cc.relname = tablename
        JOIN pg_namespace nn ON cc.relnamespace = nn.oid AND nn.nspname = schemaname
        WHERE
            schemaname = 'public'
    ) AS sml
    WHERE sml.relpages > 0
)
SELECT
    tablename,
    tbloat,
    pg_size_pretty(wastedbytes) as bloat_size,
    CASE
        WHEN wastedbytes >= 1073741824 THEN 'Critical'
        WHEN wastedbytes >= 104857600 THEN 'Warning'
        ELSE 'OK'
    END as status
FROM bloat_info
WHERE wastedbytes > 0
ORDER BY wastedbytes DESC
LIMIT 5;"
echo ""

echo -e "${BLUE}Index Usage Analysis:${NC}"
psql -d $DB_NAME -U $DB_USER -c "SELECT
    t.tablename,
    indexname,
    c.reltuples::bigint AS num_rows,
    pg_size_pretty(pg_relation_size(quote_ident(t.tablename)::text)) AS table_size,
    pg_size_pretty(pg_relation_size(quote_ident(indexrelname)::text)) AS index_size,
    idx_scan as index_scans
FROM pg_tables t
LEFT OUTER JOIN pg_class c ON t.tablename=c.relname
LEFT OUTER JOIN (
    SELECT c.relname AS ctablename, ipg.relname AS indexname, x.indexrelname, x.indrelid, x.indnatts, idx_scan, idx_tup_read, idx_tup_fetch
    FROM pg_index x
    JOIN pg_class c ON c.oid = x.indrelid
    JOIN pg_class ipg ON ipg.oid = x.indexrelid
    JOIN pg_stat_all_indexes psai ON x.indexrelid = psai.indexrelid
) AS idx_info ON t.tablename = idx_info.ctablename
WHERE t.schemaname='public'
AND idx_info.indexname IS NOT NULL
ORDER BY 1,2;"
echo ""

echo -e "${BLUE}User Engagement Metrics:${NC}"
psql -d $DB_NAME -U $DB_USER -c "SELECT
    date_trunc('day', created_at) as day,
    COUNT(id) as num_actions,
    COUNT(DISTINCT user_id) as unique_users,
    COUNT(id) / COUNT(DISTINCT user_id)::float as actions_per_user
FROM user_activity
WHERE created_at > CURRENT_TIMESTAMP - INTERVAL '7 days'
GROUP BY day
ORDER BY day DESC;"
echo ""

echo -e "${BLUE}=========================================${NC}"
echo "Monitoring complete at $(date)"
echo -e "${BLUE}=========================================${NC}"
