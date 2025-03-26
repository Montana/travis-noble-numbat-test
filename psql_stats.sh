#!/bin/bash
set -e

wait_for_postgres() {
    until psql -U postgres -c '\l' > /dev/null 2>&1; do
        echo "Waiting for PostgreSQL to be ready..."
        sleep 1
    done
    echo "PostgreSQL is ready!"
}

echo "Generating database report..."

wait_for_postgres

PG_VERSION=$(psql -U postgres -t -c "SHOW server_version;" | xargs)
echo "PostgreSQL Version: $PG_VERSION" > report.txt

TOTAL_USERS=$(psql -d test -U postgres -t -c "SELECT COUNT(*) FROM users;" | xargs)
echo "Total Users: $TOTAL_USERS" >> report.txt

ACTIVE_USERS=$(psql -d test -U postgres -t -c "SELECT COUNT(*) FROM users WHERE is_active = true;" | xargs)
echo "Active Users: $ACTIVE_USERS" >> report.txt

LATEST_LOGIN=$(psql -d test -U postgres -t -c "SELECT MAX(last_login) FROM users;" | xargs)
echo "Most Recent Login: $LATEST_LOGIN" >> report.txt

AVG_AGE=$(psql -d test -U postgres -t -c "SELECT EXTRACT(DAY FROM AVG(AGE(created_at)))::integer FROM users;" | xargs)
echo "Average Account Age (days): $AVG_AGE" >> report.txt

echo "Report generated successfully!"
echo "Report contents:"
cat report.txt
