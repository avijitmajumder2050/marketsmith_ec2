# `main.py` — Detailed Logic Explanation

`main.py` is byte-for-byte identical to `marketsmith_get_Data_v4.py`. It is the entire scraping/classification pipeline for the MarketSmith EC2 bot, run top to bottom via `run()`.

## 1. Imports & Config (lines 1–22)

```python
from aws_s3 import S3_BUCKET as ACTIVE_S3_BUCKET
```

`aws_s3.py` runs bucket-detection logic at import time (`get_working_bucket()` probes candidate buckets with `head_bucket`), so importing this name has the side effect of validating S3 access before anything else runs.

Config constants tune the scrape for a memory-constrained t3.micro instance:

| Constant | Value | Purpose |
|---|---|---|
| `BROWSER_RESET_EVERY` | 4 | Full browser teardown/relaunch every 4th symbol |
| `WAIT_BASE` | 800 (ms) | Base wait after page load before reading DOM |
| `WAIT_MAX` | 2000 (ms) | Cap on the scaled wait |
| `SLEEP_TIME` | 0.15 (s) | Throttle between symbols |

## 2. S3 I/O helpers (lines 27–34)

- **`load_csv()`** — pulls the input CSV object from S3 into memory (`BytesIO`) and parses with pandas. No local disk write.
- **`save_csv(df)`** — serializes the dataframe to an in-memory CSV buffer and `put_object`s it to `OUTPUT_KEY`. Called mid-run (checkpoint) and at the end — each call overwrites the same object, so it's always the "latest full snapshot," not an append.

## 3. In-page metric extraction — `extract_metrics_fast(page)` (lines 39–66)

This runs as **JavaScript inside the browser tab** via `page.evaluate`, not Python — it executes against the live DOM after page load:

- **`getVal(label)`**: loops every `<h4 class="modal-title">` on the page, checks if its text contains the label string (e.g. `"EPS Strength"`), and if so returns the text of the nested `<b>` tag (the numeric/grade value sits there in MarketSmith's markup). Returns `"N/A"` if the label section isn't found.
- **`getGroupRank()`**: instead of DOM-walking, regexes the *entire visible page text* for a pattern like `Group Rank ... 23 of 500` and captures just the rank number (`23`). This is a looser match than `getVal` because Group Rank isn't rendered in the same modal-title structure.
- Returns a dict of all four metrics in **one JS round-trip** (single `evaluate` call, not four) — deliberate for speed, since each `page.evaluate` call has overhead.

## 4. BSE fallback lookup — `fetch_bse_code(symbol)` (lines 71–84)

Used only when the primary NSE-symbol scrape fails outright. Hits `ticker.finology.in/company/{symbol}` with a browser-like User-Agent, regexes the HTML for `BSE: <digits>`, returns the code or `None`. Wrapped in a blanket `try/except` — any network error, timeout, or missing match just yields `None` silently, which the caller treats as "no fallback available."

## 5. Retry logic — `scrape_with_retry(page, symbol, retries=3)` (lines 89–113)

For up to 3 attempts:

1. `page.goto(url, timeout=25000, wait_until="domcontentloaded")` — waits only for DOM parse, not full load/network-idle, to stay fast.
2. Sleeps `wait = min(WAIT_BASE * (attempt + 1), WAIT_MAX)` — attempt 1 waits 800ms, attempt 2 waits 1600ms, attempt 3+ caps at 2000ms. This gives slow-loading pages progressively more time on later attempts rather than failing fast.
3. Calls `extract_metrics_fast`.
4. **Validity check**: `if metrics["EPS Strength"] not in ["N/A", "4"]: return metrics` — accepts the result only if EPS Strength is neither missing nor literally `"4"`. (The `"4"` exclusion looks like an ad-hoc guard against some known bad/placeholder value the site returns during a partial load — not a general validity rule.)
5. If invalid or an exception was thrown (`goto` timeout, JS error, etc.), it logs and falls through to `time.sleep(1)` before the next attempt.
6. After 3 failed attempts, returns `None` — signals total failure for this symbol under this identifier.

## 6. Main orchestration — `run()` (lines 118–221)

**Setup**: loads symbols from the `"Stock Name"` column, ensures the four metric columns exist on `df` (backfilled with `"N/A"` if new).

**Per-symbol loop**, for `i, symbol` in `enumerate(symbols)`:

- **Browser lifecycle** (`i % BROWSER_RESET_EVERY == 0`): on symbol 0, 4, 8, 12... it tears down any existing `page`/`context`/`browser` (best-effort, swallowing errors) and launches a brand-new Chromium instance with a specific flag set aimed at minimizing memory (`--single-process`, `--no-zygote`, `--js-flags=--max-old-space-size=96`, etc.). It also installs a network route interceptor that aborts requests for `image`/`font`/`media`/`stylesheet` resource types — only HTML/XHR/JS get through, which speeds up page loads since the script only needs text content.
- **Scrape**: `scrape_with_retry(page, symbol)`.
- **Fallback**: if that returned `None`, call `fetch_bse_code(symbol)`; if a BSE code was found, retry the *entire* `scrape_with_retry` flow again using the BSE code as the URL symbol instead.
- **Write-back**: if metrics were obtained (from either path), build a boolean `mask = df["Stock Name"] == symbol` and assign each metric key/value into the matching row(s) via `df.loc[mask, k] = v`. If still `None`, the row keeps its `"N/A"` defaults.
- **Memory cleanup**: navigates the page to `about:blank` after every symbol (not just on reset cycles) to release the previous page's DOM/JS heap without a full browser relaunch, then sleeps `SLEEP_TIME`.
- **Checkpoint**: every 10th symbol (`(i + 1) % 10 == 0`), calls `save_csv(df)` to persist progress to S3 — so a crash mid-run loses at most 9 symbols of new data.

**After the loop**: closes page/context/browser, does a final `save_csv(df)` to persist the complete result set.

## 7. Setup-case classification (lines 225–290, nested inside `run()`)

Defined as a nested function and invoked only after all scraping is done:

- **`stock_case(row)`**:
  - Gate: `Price Strength < 80` → immediately `None` (excluded from all cases).
  - Otherwise starts `matches = 1` (the Price Strength pass counts as the first match) and adds one point each for:
    - `EPS Strength >= 80`
    - `Buyer Demand` value starts with `"A"` or `"B"` (case-insensitive via `.upper()`) — i.e. grade A or B.
    - `Group Rank < 40` (lower rank number = stronger, since it's "N of M" ranking).
  - Maps final `matches` count to a label: `4 → "Case A"`, `3 → "Case B"`, `2 → "Case C"`, anything else (just the base 1) → `None` (via `dict.get` returning `None` for unmapped keys).
  - Any exception (e.g., `"N/A"` failing `float()` conversion) is caught and returns `None` — so incomplete-data rows are silently excluded rather than crashing the classification pass.
- Applied row-wise via `df.apply(stock_case, axis=1)` into a new `Setup_Case` column.
- `filtered_df` keeps only rows where `Setup_Case` is one of the three case labels.
- This filtered set is written to S3 twice:
  - `chartmaza-data/output/marketsmith_setups.csv` (canonical output)
  - `uploads/mapping.csv` (same bytes, different key — likely a location a separate downstream consumer/uploader watches)

## Net effect

The scrape phase builds a complete metrics table for every input symbol (best-effort, `"N/A"` where scraping failed even after BSE fallback), and the classification phase is a pure post-filter over that table with no interaction back into the scrape logic — so a symbol that fails to scrape simply can't qualify for any `Setup_Case`, it doesn't error the pipeline.

## Notable quirks / caveats

- The `if metrics["EPS Strength"] not in ["N/A", "4"]` check treats an EPS Strength literally equal to the string `"4"` as bad data — likely a leftover heuristic from a specific bad-scrape pattern, not an obviously general rule.
- Almost every failure path is swallowed by bare `except: pass` / `except Exception as e: print(...)` — the script prioritizes finishing the run over surfacing errors, consistent with it running unattended on a disposable EC2 box.
- `stock_case`'s field reads (`row.get(...)`) will silently coerce missing/`"N/A"` values via `float()`, which raises and is caught by the outer `except: return None` — so any row with genuinely missing data is just excluded rather than erroring the whole run.
- `requirements.txt` currently lists only `pandas` and `requests`; `main.py` also needs `boto3` and `playwright`, installed separately by `user_data.sh`.
- `user_data.sh` runs under `set -e`, so a crash in `python main.py` aborts the script before the log-upload/terminate steps — the EC2 instance is left running indefinitely instead of self-terminating.
