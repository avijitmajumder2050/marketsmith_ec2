# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A batch scraping bot that runs on a disposable EC2 instance: it pulls a symbol list from S3, scrapes evaluation metrics (EPS Strength, Price Strength, Buyer Demand, Group Rank) from marketsmithindia.com via headless Playwright/Chromium, classifies stocks into setup cases, writes results back to S3, then the EC2 instance terminates itself.

## Commands

```bash
pip install -r requirements.txt          # NOTE: incomplete — see below
pip install playwright boto3
python -m playwright install chromium
python main.py                           # requires AWS creds + S3 bucket access
```

There is no test suite, linter, or CI config in this repo.

`requirements.txt` currently lists only `pandas` and `requests`; `main.py` actually also needs `boto3` and `playwright`. The EC2 bootstrap script (`user_data.sh`) installs these separately via an explicit `pip install playwright requests pandas boto3 beautifulsoup4` line rather than relying on `requirements.txt`, so don't assume `requirements.txt` alone is sufficient to run the bot.

## Architecture

**`main.py`** is the entire pipeline, run top to bottom via `run()`:
1. Load symbol list from `s3://<bucket>/chartmaza-data/input/raw_mapping_all_symbols.csv` (`load_csv`).
2. For each symbol, open `https://marketsmithindia.com/mstool/eval/{symbol}/evaluation.jsp#/` and scrape metrics via in-page JS (`extract_metrics_fast`), with retry/backoff (`scrape_with_retry`). If a symbol fails, fall back to looking up its BSE code (`fetch_bse_code`, via ticker.finology.in) and retrying under that code.
3. The browser is hard-reset every `BROWSER_RESET_EVERY` (4) symbols to avoid memory buildup/hangs on the small EC2 instance — this is deliberate, not incidental. Image/font/media/stylesheet requests are blocked at the route level to keep scraping fast.
4. Progress is checkpointed to S3 every 10 symbols (`save_csv`), then again at the end.
5. After scraping, `stock_case()` classifies each row into Case A/B/C based on Price/EPS Strength, Buyer Demand grade, and Group Rank thresholds; qualifying rows are written to `chartmaza-data/output/marketsmith_setups.csv` and duplicated to `uploads/mapping.csv`.

**`aws_s3.py`** resolves which S3 bucket to use at import time: `get_working_bucket()` probes `BUCKET_CANDIDATES` (env `S3_BUCKET`, then `dhan-trading-data`, `new-dhan-trading-data`) with `head_bucket` and picks the first accessible one, raising if none are reachable. `main.py` imports `S3_BUCKET` from here as `ACTIVE_S3_BUCKET`. This module also exposes `read_csv_from_s3` / `list_s3_files` helpers, though `main.py` uses its own local `load_csv`/`save_csv` instead of these.

**`user_data.sh`** is the EC2 bootstrap/user-data script: installs OS packages + Playwright's native deps, clones this repo, sets up a venv, installs Chromium, runs `python main.py` in the foreground, uploads the log to S3, then terminates the instance via the EC2 metadata service (IMDSv2 token flow). Because the script runs under `set -e`, a failure in `python main.py` will currently abort the script before the log-upload/terminate steps run — be aware of this when touching that script, since it means a crash leaves the instance running indefinitely instead of self-terminating.

There are duplicate/superseded files at the repo root (`marketsmith_get_Data_v1.py` through `v4.py`, `user_data copy*.sh`) that are earlier iterations of `main.py` / `user_data.sh` respectively — `main.py` and `marketsmith_get_Data_v4.py` are currently identical. Treat `main.py` and `user_data.sh` as the canonical versions.
