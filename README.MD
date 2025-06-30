# PostgreSQL Health Report Generator

This is a modular shell script to generate PostgreSQL health reports in HTML, JSON, or plain text formats.

##  Key Features

- Bloat info, unused indexes, long-running queries
- Autovacuum stats, replication lag, temp usage
- Index usage, memory config, cache hit ratio
- JSON, text, HTML output formats
- Recommended vs full mode filtering
- Secure `.pgpass` and `.env` based credential handling

##  Setup

1. Clone the repo:

git clone https://github.com/softclement/pg_health_report.git
cd pg_health_report


Create your environment config:

cp db_config.env.sample db_config.env
# Edit db_config.env with actual DB info

Add entry to your .pgpass:

localhost:5432:your_db:your_user:your_password

Make sure it has correct permissions:
chmod 600 ~/.pgpass


USAGE 
./pg_health_report_advanced.sh


Optional flags:

    --report-mode=full or --report-mode=recommended
    --format=html, --format=json, --format=text
    --serve (serve HTML via Python web server)


./pg_health_report_advanced.sh --report-mode=recommended --format=html --serve

Recommended Cronjob Setup
Daily Report at 7 AM:

0 7 * * * /home/postgres/pg_health_report/pg_health_report_advanced.sh --report-mode=recommended --format=html > /dev/null 2>&1

Weekly Full Report Every Sunday at 6 AM:

0 6 * * 0 /home/postgres/pg_health_report/pg_health_report_advanced.sh --report-mode=full --format=html > /dev/null 2>&1

