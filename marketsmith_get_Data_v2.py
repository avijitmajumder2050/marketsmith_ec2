import pandas as pd
import time
import re
import boto3
import requests
from io import BytesIO
from playwright.sync_api import sync_playwright

# ─────────────────────────────────────────────
# CONFIG (t3.micro OPTIMIZED)
# ─────────────────────────────────────────────
BUCKET = "dhan-trading-data"
INPUT_KEY = "chartmaza-data/input/raw_mapping_all_symbols.csv"
OUTPUT_KEY = "chartmaza-data/output/marketsmith_output.csv"

BROWSER_RESET_EVERY = 4     # 🔥 more frequent reset (prevents hang)
WAIT_BASE = 800             # 🔥 dynamic wait base (faster)
WAIT_MAX = 2000             # max wait
SLEEP_TIME = 0.15           # 🔥 ultra low throttle

s3 = boto3.client("s3")

# ─────────────────────────────────────────────
# S3
# ─────────────────────────────────────────────
def load_csv():
    obj = s3.get_object(Bucket=BUCKET, Key=INPUT_KEY)
    return pd.read_csv(BytesIO(obj["Body"].read()))

def save_csv(df):
    buffer = BytesIO()
    df.to_csv(buffer, index=False)
    s3.put_object(Bucket=BUCKET, Key=OUTPUT_KEY, Body=buffer.getvalue())

# ─────────────────────────────────────────────
# FAST JS EXTRACTION
# ─────────────────────────────────────────────
def extract_metrics_fast(page):
    return page.evaluate("""
        () => {
            function getVal(label) {
                let els = document.querySelectorAll("h4.modal-title");
                for (let el of els) {
                    if (el.innerText.includes(label)) {
                        let b = el.querySelector("b");
                        if (b) return b.innerText.trim();
                    }
                }
                return "N/A";
            }

            function getGroupRank() {
                let txt = document.body.innerText;
                let m = txt.match(/Group Rank.*?(\\d+)\\s+of\\s+\\d+/i);
                return m ? m[1] : "N/A";
            }

            return {
                "EPS Strength": getVal("EPS Strength"),
                "Price Strength": getVal("Price Strength"),
                "Buyer Demand": getVal("Buyer Demand"),
                "Group Rank": getGroupRank()
            };
        }
    """)

# ─────────────────────────────────────────────
# FETCH BSE CODE (fallback)
# ─────────────────────────────────────────────
def fetch_bse_code(symbol):
    try:
        r = requests.get(
            f"https://ticker.finology.in/company/{symbol}",
            headers={"User-Agent": "Mozilla/5.0"},
            timeout=6
        )
        if r.status_code != 200:
            return None

        m = re.search(r"BSE:\s*(\d+)", r.text)
        return m.group(1) if m else None
    except:
        return None

# ─────────────────────────────────────────────
# SMART RETRY (dynamic wait)
# ─────────────────────────────────────────────
def scrape_with_retry(page, symbol, retries=3):

    url = f"https://marketsmithindia.com/mstool/eval/{symbol}/evaluation.jsp#/"

    for attempt in range(retries):
        try:
            page.goto(url, timeout=25000, wait_until="domcontentloaded")

            # 🔥 dynamic wait (faster on success)
            wait = min(WAIT_BASE * (attempt + 1), WAIT_MAX)
            page.wait_for_timeout(wait)

            metrics = extract_metrics_fast(page)

            if metrics["EPS Strength"] not in ["N/A", "4"]:
                return metrics

            print(f"Retry {attempt+1} → bad data")

        except Exception as e:
            print(f"Retry {attempt+1} → {e}")

        time.sleep(1)

    return None

# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────
def run():

    df = load_csv()
    symbols = df["Stock Name"].tolist()

    cols = ["EPS Strength", "Price Strength", "Buyer Demand", "Group Rank"]
    for col in cols:
        if col not in df.columns:
            df[col] = "N/A"

    with sync_playwright() as p:

        browser = None
        context = None
        page = None

        for i, symbol in enumerate(symbols):

            print(f"\n{i+1}/{len(symbols)} → {symbol}")

            # 🔥 HARD RESET (prevents EC2 freeze)
            if i % BROWSER_RESET_EVERY == 0:

                if browser:
                    print("♻️ Restart browser")
                    try:
                        page.close()
                        context.close()
                        browser.close()
                    except:
                        pass

                browser = p.chromium.launch(
                    headless=True,
                    args=[
                        "--no-sandbox",
                        "--disable-dev-shm-usage",
                        "--disable-gpu",
                        "--single-process",
                        "--no-zygote",
                        "--disable-extensions",
                        "--disable-background-networking",
                        "--disable-renderer-backgrounding",
                        "--disable-sync",
                        "--disable-features=site-per-process",
                        "--memory-pressure-off",
                        "--js-flags=--max-old-space-size=96"
                    ]
                )

                context = browser.new_context()

                # 🔥 BLOCK HEAVY RESOURCES
                context.route("**/*", lambda route:
                    route.abort() if route.request.resource_type in ["image", "font", "media", "stylesheet"]
                    else route.continue_()
                )

                page = context.new_page()

            # ───── SCRAPE ─────
            metrics = scrape_with_retry(page, symbol)

            # ───── FALLBACK ─────
            if metrics is None:
                print("⚠️ fallback BSE")

                bse = fetch_bse_code(symbol)
                if bse:
                    metrics = scrape_with_retry(page, bse)

            # ───── SAVE RESULT ─────
            if metrics:
                print("✅", metrics)

                mask = df["Stock Name"] == symbol
                for k, v in metrics.items():
                    df.loc[mask, k] = v
            else:
                print("❌ failed")

            # 🔥 CLEAN MEMORY (VERY IMPORTANT)
            try:
                page.goto("about:blank", timeout=5000)
            except:
                pass

            time.sleep(SLEEP_TIME)

            # 🔥 SAVE PROGRESS
            if (i + 1) % 10 == 0:
                save_csv(df)
                print("💾 saved")

        # 🔥 FINAL CLEANUP
        try:
            page.close()
            context.close()
            browser.close()
        except:
            pass

    save_csv(df)
    print("\n✅ COMPLETED")

# ─────────────────────────────────────────────
if __name__ == "__main__":
    run()