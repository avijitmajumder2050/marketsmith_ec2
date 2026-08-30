# Reusable Prompt — Build a Similar Scraping/Classification Pipeline

Sample prompt for generating a pipeline architecturally similar to `main.py`
(resource-constrained batch scraping + retry/fallback + checkpointing +
rule-based classification). Adapt the placeholders (`<...>`) for a new
target site/use case.

```
Build a Python batch web-scraping script (main.py) with this architecture:

CONTEXT
- Runs unattended on a small/disposable cloud VM (e.g. t3.micro, 1GB RAM) that
  terminates itself after the script finishes.
- Input: a list of ~N identifiers (symbols/IDs) stored as a CSV in S3.
- For each identifier, scrape a set of metrics from a specific webpage via
  headless Playwright (Chromium), then classify each row into categories
  based on threshold rules, and write the classified subset back to S3.

DATA FLOW
1. Load input CSV from s3://<bucket>/<input-key> into a pandas DataFrame.
2. Ensure output metric columns exist on the DataFrame (default "N/A").
3. For each row's identifier:
   a. Navigate to https://<target-site>/<identifier>/page.
   b. Extract N metrics from the DOM via a single page.evaluate() JS call
      (not one call per metric) for speed.
   c. If extraction returns invalid/placeholder data, retry up to 3x with
      an increasing wait time between attempts (e.g. 800ms, 1600ms, capped
      at 2000ms) before giving up.
   d. If all retries fail under the primary identifier, look up an
      alternate identifier via a secondary source (HTTP GET + regex) and
      retry the scrape under that alternate ID.
   e. Write successfully scraped metrics back into the matching DataFrame
      row(s) by identifier.
4. Memory management for the constrained VM:
   - Block image/font/media/stylesheet network requests at the route level
     (only HTML/XHR/JS needed).
   - Fully close and relaunch the browser every K rows (e.g. every 4) to
     avoid memory creep/hangs — don't rely on page.close() alone.
   - Navigate to about:blank after each row to release page memory between
     the periodic full resets.
   - Launch Chromium with memory-lean flags (--single-process, --no-zygote,
     --disable-gpu, --js-flags=--max-old-space-size=<small>, etc.).
5. Checkpoint the DataFrame to S3 every M rows (e.g. every 10) so a crash
   loses minimal progress; also save once at the end.
6. Classification pass (after all scraping):
   - Define a per-row scoring function with a hard gate on one primary
     metric threshold (row excluded entirely if it fails the gate).
   - Add one point per additional metric that clears its own threshold.
   - Map the total score to named categories (e.g. 4/4 -> "Case A",
     3/4 -> "Case B", 2/4 -> "Case C"); anything else -> excluded.
   - Wrap the scoring function in try/except returning None on bad/missing
     data rather than raising.
   - Filter to only categorized rows and write that subset to one or more
     S3 output keys (e.g. a canonical output path and a second path a
     downstream consumer watches).

ERROR HANDLING PHILOSOPHY
- This is an unattended batch job — prioritize finishing the full run over
  surfacing individual errors. Wrap risky per-row operations (network
  calls, browser actions, teardown) in try/except that logs and continues
  rather than aborting the whole script.

DELIVERABLE
- Single script, e.g. main.py, with clearly separated functions: S3
  load/save, JS metric extraction, fallback ID lookup, retry-wrapped
  scrape, main loop, classification. Use boto3 for S3, requests for the
  fallback lookup, playwright.sync_api for scraping, pandas for the
  DataFrame.
- Also produce a shell bootstrap script that installs OS-level Playwright
  deps, sets up a venv, runs the script in the foreground, uploads the
  log to S3, and terminates the instance via the cloud provider's
  metadata service — note explicitly whether `set -e` is used and what
  that means for self-termination on script failure.
```

## Notes when adapting this prompt

- Swap the target site, identifier type, metric names/thresholds, and
  S3 key layout for the new use case.
- The `K` (browser reset cadence) and `M` (checkpoint cadence) constants
  should scale with the VM's available memory and the total row count —
  `main.py` uses `K=4`, `M=10` for a t3.micro run of a few hundred symbols.
- If the new target site doesn't need a fallback-identifier lookup step,
  drop 3(d) — it exists in `main.py` specifically because NSE symbols
  sometimes don't resolve directly and need a BSE code substitute.

See [`main_logic.md`](./main_logic.md) for the line-by-line breakdown of
the actual implementation this prompt is derived from.
