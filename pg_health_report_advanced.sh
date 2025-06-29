#!/bin/bash

###############################################################################
# PostgreSQL Health Report Generator (Modular & Enhanced)
#
# Version History:
# ------------------------------------------------------------------------------
# Version | Date        | Author   | Description
# ------- | ----------  | -------- | --------------------------------------------
# 1.0     | 01-Jun-2025 | Clement  | Initial version with basic health checks
#         |             |          | (bloat, unused indexes, long queries, vacuum,
#         |             |          | replication lag, DB sizes).
# 1.1     | 03-Jun-2025 | Clement  | Added autovacuum activity, slow queries from
#         |             |          | pg_stat_statements, temp usage, index usage.
# 1.2     | 05-Jun-2025 | Clement  | Improved HTML formatting, added timestamps,
#         |             |          | layout refinements, inline CSS.
# 1.3     | 08-Jun-2025 | Clement  | Externalized DB config using db_config.env,
#         |             |          | added .pgpass validation.
# 1.4     | 10-Jun-2025 | Clement  | Added command-line args: --report-mode,
#         |             |          | --format, --serve. Multiple output types.
# 1.5     | 12-Jun-2025 | Clement  | Added JSON and plain text generators,
#         |             |          | with CSV parsing and fallback formatting.
# 1.6     | 15-Jun-2025 | Clement  | Introduced "recommended" vs "full" modes
#         |             |          | using keyword-based section filtering.
# 1.7     | 18-Jun-2025 | Clement  | Fixed associative array randomness by using
#         |             |          | ORDERED_KEYS for deterministic section output.
# 1.8     | 21-Jun-2025 | Clement  | Added memory config, buffer cache hit ratio,
#         |             |          | advisory locks, wraparound risk, PK check.
# 1.9     | 24-Jun-2025 | Clement  | Added SQL presence validation to avoid
#         |             |          | COPY (LIMIT) syntax errors.
# 1.9.1   | 27-Jun-2025 | Clement  | Improved slow query filters (skip COPY,
#         |             |          | SELECT datname, etc.). Logged SQL skips.
# 1.9.2   | 28-Jun-2025 | Clement  | Bloat Info now includes live/dead tuples,
#         |             |          | mod count; improved pg_stat_statements filters.
# 2.0-pre | 29-Jun-2025 | Clement  | Modularized output logic with render_section(),
#         |             |          | DRY structure, ready for GitHub publication.
###############################################################################


# === CONFIG LOADING ===
CONFIG_FILE="./db_config.env"
[[ ! -f "$CONFIG_FILE" ]] && echo "Error: $CONFIG_FILE not found." && exit 1
source "$CONFIG_FILE"

for var in DBHOST DBPORT DBNAME DBUSER; do
  [[ -z "${!var}" ]] && echo "Error: $var not set in $CONFIG_FILE" && exit 1
done

PGPASS="$HOME/.pgpass"
[[ ! -f "$PGPASS" ]] && echo "Error: .pgpass file not found." && exit 1
grep -q "^$DBHOST:$DBPORT:$DBNAME:$DBUSER:" "$PGPASS" || {
  echo "Error: No matching line in .pgpass for $DBHOST:$DBPORT:$DBNAME:$DBUSER"
  exit 1
}

# === DEFAULTS & SETUP ===
PSQL="psql -h $DBHOST -U $DBUSER -d $DBNAME -p $DBPORT -At -F','"
TODAY=$(date +%F)
BASE_DIR="$HOME/pg_health_reports"
mkdir -p "$BASE_DIR/$TODAY"

REPORT_MODE="full"
FORMAT="html"
SERVE="no"

for arg in "$@"; do
  case $arg in
    --report-mode=full) REPORT_MODE="full" ;;
    --report-mode=recommended) REPORT_MODE="recommended" ;;
    --format=html) FORMAT="html" ;;
    --format=json) FORMAT="json" ;;
    --format=text) FORMAT="text" ;;
    --serve) SERVE="yes" ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

OUTFILE_BASENAME="report_${REPORT_MODE}"
HTML_FILE="$BASE_DIR/$TODAY/${OUTFILE_BASENAME}.html"
JSON_FILE="$BASE_DIR/$TODAY/${OUTFILE_BASENAME}.json"
TEXT_FILE="$BASE_DIR/$TODAY/${OUTFILE_BASENAME}.txt"

# === SECTION KEYS (Ordered) ===
ORDERED_KEYS=( 
  "1. Bloat Info (Dead Tuple %)"
  "2. Unused Indexes"
  "3. Long-Running Queries (> 5 min)"
  "4. Vacuum Stats"
  "5. Replication Lag"
  "6. DB Sizes"
  "7. Temp File Usage"
  "8. Connection Stats"
  "9. Slow Queries (pg_stat_statements)"
  "10. Autovacuum & Autoanalyze Activity"
  "11. Index Usage Efficiency"
  "12. Buffer Cache Hit Ratio"
  "13. Memory Configuration Parameters"
  "14. Connection Stats by State/User"
  "15. Oldest Transaction Age (Wraparound Risk)"
  "16. Advisory Locks (if used)"
  "17. Tables Without Primary or Foreign Key"
)

# === SQL MAP ===
declare -A SECTIONS
SECTIONS["1. Bloat Info (Dead Tuple %)"]="SELECT schemaname, relname, n_live_tup, n_dead_tup, n_mod_since_analyze, round((n_dead_tup::numeric / (n_live_tup + 1)) * 100, 2) AS dead_pct FROM pg_stat_user_tables ORDER BY dead_pct DESC"
SECTIONS["2. Unused Indexes"]="SELECT schemaname, relname, indexrelname, idx_scan FROM pg_stat_user_indexes WHERE idx_scan = 0 AND indexrelid NOT IN (SELECT conindid FROM pg_constraint WHERE contype IN ('p','u'))"
SECTIONS["3. Long-Running Queries (> 5 min)"]="SELECT pid, usename, now() - query_start AS runtime, state, LEFT(query, 100) FROM pg_stat_activity WHERE state <> 'idle' AND now() - query_start > interval '5 minutes'"
SECTIONS["4. Vacuum Stats"]="SELECT relname, n_dead_tup, last_vacuum, last_autovacuum FROM pg_stat_user_tables ORDER BY n_dead_tup DESC"
SECTIONS["5. Replication Lag"]="SELECT client_addr, state, pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag FROM pg_stat_replication"
SECTIONS["6. DB Sizes"]="SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY pg_database_size(datname) DESC"
SECTIONS["7. Temp File Usage"]="SELECT datname, temp_files, pg_size_pretty(temp_bytes) FROM pg_stat_database ORDER BY temp_bytes DESC"
SECTIONS["8. Connection Stats"]="SELECT usename, state, COUNT(*) FROM pg_stat_activity GROUP BY usename, state ORDER BY COUNT(*) DESC"
SECTIONS["9. Slow Queries (pg_stat_statements)"]="SELECT regexp_replace(LEFT(query, 100), '[\\n\\r]+', ' ', 'g') AS query, calls, round(total_exec_time::numeric, 2), round((total_exec_time / NULLIF(calls, 0))::numeric, 2) AS avg_ms, rows FROM pg_stat_statements WHERE query NOT ILIKE '%pg_stat_statements%' AND query NOT ILIKE 'COPY %' AND query NOT ILIKE 'SELECT datname%' ORDER BY total_exec_time DESC"
SECTIONS["10. Autovacuum & Autoanalyze Activity"]="SELECT relname, n_tup_ins, n_tup_upd, n_tup_del, autovacuum_count, autoanalyze_count FROM pg_stat_user_tables ORDER BY autovacuum_count DESC"
SECTIONS["11. Index Usage Efficiency"]="SELECT relname, idx_scan, seq_scan, ROUND(100.0 * idx_scan / GREATEST(idx_scan + seq_scan, 1), 2) AS index_usage_pct FROM pg_stat_user_tables ORDER BY index_usage_pct ASC"
SECTIONS["12. Buffer Cache Hit Ratio"]="SELECT ROUND(SUM(blks_hit) * 100.0 / GREATEST(SUM(blks_hit + blks_read),1), 2) AS hit_ratio_pct FROM pg_stat_database"
SECTIONS["13. Memory Configuration Parameters"]="SELECT name, setting FROM pg_settings WHERE name IN ('work_mem','maintenance_work_mem','shared_buffers','effective_cache_size')"
SECTIONS["14. Connection Stats by State/User"]="SELECT usename, state, COUNT(*) FROM pg_stat_activity GROUP BY usename, state ORDER BY COUNT(*) DESC"
SECTIONS["15. Oldest Transaction Age (Wraparound Risk)"]="SELECT datname, age(datfrozenxid) AS xid_age FROM pg_database ORDER BY xid_age DESC"
SECTIONS["16. Advisory Locks (if used)"]="SELECT pid, locktype, mode, granted, query FROM pg_locks JOIN pg_stat_activity USING (pid) WHERE locktype = 'advisory'"
SECTIONS["17. Tables Without Primary or Foreign Key"]="SELECT relname FROM pg_stat_user_tables WHERE relid NOT IN (SELECT conrelid FROM pg_constraint WHERE contype IN ('p','f'))"

# === FILTER FUNCTION ===
should_include_section() {
  local title="$1"
  [[ "$REPORT_MODE" == "full" ]] && return 0
  [[ "$title" =~ "Bloat" || "$title" =~ "Unused" || "$title" =~ "Long-Running" || "$title" =~ "Slow" || "$title" =~ "Replication" || "$title" =~ "Wraparound Risk" || "$title" =~ "Cache Hit Ratio" || "$title" =~ "Primary" ]] && return 0
  return 1
}

# === SHARED RENDER FUNCTION ===
render_section() {
  local title="$1" sql="$2" format="$3"
  [[ -z "$sql" ]] && echo "Warning: Missing SQL for '$title'" >&2 && return

  case "$format" in
    html)
      echo "<h2>$title</h2><table>" >> "$HTML_FILE"
      local header=$($PSQL -c "COPY ( $sql LIMIT 1 ) TO STDOUT WITH CSV HEADER" | head -1)
      IFS=',' read -ra HEADS <<< "$header"
      echo "<tr>" >> "$HTML_FILE"
      for h in "${HEADS[@]}"; do echo "<th>$h</th>" >> "$HTML_FILE"; done
      echo "</tr>" >> "$HTML_FILE"
      $PSQL -c "COPY ( $sql LIMIT 50 ) TO STDOUT WITH CSV" | while IFS=',' read -r row; do
        echo "<tr>" >> "$HTML_FILE"
        IFS=',' read -ra cols <<< "$row"
        for val in "${cols[@]}"; do echo "<td>${val//</&lt;}</td>" >> "$HTML_FILE"; done
        echo "</tr>" >> "$HTML_FILE"
      done
      echo "</table>" >> "$HTML_FILE"
      ;;
    text)
      echo -e "\n== $title ==" >> "$TEXT_FILE"
      $PSQL -c "$sql LIMIT 10" >> "$TEXT_FILE"
      ;;
    json)
      echo "\"$title\": [" >> "$JSON_FILE"
      $PSQL -c "COPY ( $sql LIMIT 10 ) TO STDOUT WITH CSV HEADER" | awk -F',' '
        NR==1 { for(i=1;i<=NF;i++) h[i]=$i; next }
        {
          printf "  {\n";
          for(i=1;i<=NF;i++) {
            printf "    \"%s\": \"%s\"", h[i], $i;
            if(i<NF) printf ",\n"; else printf "\n";
          }
          printf "  },\n";
        }' | sed '$s/},/}/' >> "$JSON_FILE"
      echo "]" >> "$JSON_FILE"
      ;;
  esac
}

# === GENERATE FORMAT OUTPUT ===
generate_html() {
  cat <<EOF > "$HTML_FILE"
<!DOCTYPE html><html><head><meta charset="utf-8">
<title>PostgreSQL Health Report</title>
<style>body{font-family:Arial;}table{border-collapse:collapse;width:100%;margin:20px 0;}th,td{border:1px solid #ccc;padding:6px;font-size:14px;}th{background:#dceeff;}</style>
</head><body>
<h1>PostgreSQL Master Health Check Report</h1>
<p><strong>Date:</strong> $(date)<br><strong>Host:</strong> $DBHOST<br><strong>DB:</strong> $DBNAME<br><strong>User:</strong> $DBUSER<br><strong>Mode:</strong> $REPORT_MODE</p>
EOF
  for title in "${ORDERED_KEYS[@]}"; do
    should_include_section "$title" && render_section "$title" "${SECTIONS[$title]}" "html"
  done
  echo "<p><small>Generated on $(date)</small></p></body></html>" >> "$HTML_FILE"
  echo "HTML report saved: $HTML_FILE"
}

generate_text() {
  echo "PostgreSQL Master Health Check Report - $TODAY" > "$TEXT_FILE"
  echo "Host: $DBHOST | DB: $DBNAME | User: $DBUSER | Mode: $REPORT_MODE" >> "$TEXT_FILE"
  for title in "${ORDERED_KEYS[@]}"; do
    should_include_section "$title" && render_section "$title" "${SECTIONS[$title]}" "text"
  done
  echo "Text report saved: $TEXT_FILE"
}

generate_json() {
  echo "{" > "$JSON_FILE"
  local first=1
  for title in "${ORDERED_KEYS[@]}"; do
    should_include_section "$title" || continue
    [[ $first -eq 0 ]] && echo "," >> "$JSON_FILE"
    first=0
    render_section "$title" "${SECTIONS[$title]}" "json"
  done
  echo "}" >> "$JSON_FILE"
  echo "JSON report saved: $JSON_FILE"
}

# === MAIN DISPATCH ===
case "$FORMAT" in
  html) generate_html ;;
  text) generate_text ;;
  json) generate_json ;;
esac

[[ "$SERVE" == "yes" && "$FORMAT" == "html" ]] && {
  echo "Serving report at http://localhost:8000"
  cd "$BASE_DIR/$TODAY"
  python3 -m http.server 8000
}
