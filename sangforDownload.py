"""
Sangfor HCI VM Report Downloader

Logs into Sangfor HCI Manager via headless browser, triggers VM report,
downloads the CSV file, and saves it locally.
"""

import os
import sys
import time
from datetime import datetime
from pathlib import Path

from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeoutError
from dotenv import load_dotenv


# =========================
# Load .env
# =========================

SCRIPT_DIR = Path(__file__).parent.resolve()
load_dotenv(SCRIPT_DIR / ".env")

SANGFOR_URL      = os.getenv("SANGFOR_URL")
SANGFOR_USER     = os.getenv("SANGFOR_USER")
SANGFOR_PASSWORD = os.getenv("SANGFOR_PASSWORD")

if not all([SANGFOR_URL, SANGFOR_USER, SANGFOR_PASSWORD]):
    print("ERROR: Missing SANGFOR_URL, SANGFOR_USER, or SANGFOR_PASSWORD in .env",
          file=sys.stderr)
    sys.exit(1)


# =========================
# Cleanup old CSVs
# =========================

for old in SCRIPT_DIR.glob("sangforinfo_*.csv"):
    try:
        old.unlink()
    except Exception:
        pass


# =========================
# Output filename
# =========================

timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
output_csv = SCRIPT_DIR / f"sangforinfo_{timestamp}.csv"


# =========================
# Sangfor-specific selectors
# =========================

LOGIN_FORM   = ".uedc-ppkg-login_product-form"
USER_INPUT   = f'{LOGIN_FORM} input[name="user"]'
PASS_INPUT   = f'{LOGIN_FORM} input[name="password"]'
AGREE_CHECK  = f'{LOGIN_FORM} input[type="checkbox"]'
LOGIN_BTN    = f'{LOGIN_FORM} button.uedc-ppkg-login_product-submit'


# =========================
# Helpers
# =========================

def cookies_dict(context):
    """Convert context.cookies() to a {name: value} dict."""
    return {c["name"]: c["value"] for c in context.cookies()}


# =========================
# Playwright flow
# =========================

def run():
    with sync_playwright() as p:

        browser = p.chromium.launch(
            headless=True,
            args=["--ignore-certificate-errors"],
        )

        context = browser.new_context(
            ignore_https_errors=True,
            accept_downloads=True,
        )

        page = context.new_page()

        # ---- Step 1: Login ----

        print(f"Opening {SANGFOR_URL}/login ...")
        page.goto(f"{SANGFOR_URL}/login", wait_until="networkidle", timeout=30000)

        page.wait_for_selector(LOGIN_FORM, state="visible", timeout=10000)

        print("Filling credentials...")
        page.fill(USER_INPUT, SANGFOR_USER)
        page.fill(PASS_INPUT, SANGFOR_PASSWORD)

        # Check agreement checkbox if present
        try:
            checkbox = page.locator(AGREE_CHECK).first
            if checkbox.count() > 0 and not checkbox.is_checked():
                print("Checking agreement checkbox...")
                checkbox.check()
        except Exception as e:
            print(f"Note: Couldn't check agreement checkbox: {e}")

        print("Clicking Log In...")
        try:
            page.click(LOGIN_BTN, timeout=5000)
        except PlaywrightTimeoutError:
            try:
                page.click(f'{LOGIN_FORM} button:has-text("Log In")', timeout=3000)
            except PlaywrightTimeoutError:
                print("ERROR: Could not click login button")
                page.screenshot(path=str(SCRIPT_DIR / "debug_login.png"))
                browser.close()
                sys.exit(1)

        try:
            page.wait_for_url(lambda url: "/login" not in url, timeout=15000)
            print("Login successful")
        except PlaywrightTimeoutError:
            print("ERROR: Login appears to have failed (still on login page).")
            page.screenshot(path=str(SCRIPT_DIR / "debug_login_failed.png"))
            browser.close()
            sys.exit(1)

        # Give the page a moment to finish setting all cookies/tokens
        page.wait_for_load_state("networkidle", timeout=10000)
        time.sleep(1)

        # ---- Extract auth tokens from cookies ----

        ck = cookies_dict(context)

        csrf_token   = ck.get("CSRFPreventionToken")
        client_token = ck.get("aCMPAuthToken")

        if not csrf_token or not client_token:
            print(f"ERROR: Missing auth tokens in cookies. Got: {list(ck.keys())}")
            browser.close()
            sys.exit(1)

        print(f"CSRFPreventionToken: {csrf_token[:8]}...")
        print(f"client_token       : {client_token[:8]}...")

        auth_headers = {
            "CSRFPreventionToken": csrf_token,
            "client_token":        client_token,
            "X-Requested-With":    "XMLHttpRequest",
            "Content-Type":        "application/json; charset=UTF-8",
            "Accept":              "*/*",
            "Origin":              SANGFOR_URL,
            "Referer":             f"{SANGFOR_URL}/",
        }

        # ---- Step 2: Trigger report generation ----

        print("Triggering report generation...")
        report_payload = {
            "resource_type": "vm",
            "query_string": {},
            "options": {
                "custom_attributes": [],
                "view_columns": [
                    "status", "name", "az_name", "group_name", "os_name",
                    "secret_name", "ips", "floatingip", "cores", "cpu_status",
                    "memory_mb", "memory_status", "storage_mb", "storage_status",
                    "run_host", "storage_used", "mem_used", "mhz", "cpu_reserve"
                ]
            }
        }

        report_resp = page.request.post(
            f"{SANGFOR_URL}/admin/resource-reports",
            data=report_payload,
            headers=auth_headers,
        )

        if not report_resp.ok:
            print(f"ERROR: Report request HTTP failed: {report_resp.status} {report_resp.status_text}")
            print(f"Response: {report_resp.text()}")
            browser.close()
            sys.exit(1)

        report_data = report_resp.json()
        print(f"Report response: {report_data}")

        if report_data.get("success") != 1:
            print(f"ERROR: Report generation failed: {report_data}")
            browser.close()
            sys.exit(1)

        report_id = report_data["data"]["report_id"]
        print(f"Report ID: {report_id}")

        # ---- Step 3: Download CSV ----

        download_url = f"{SANGFOR_URL}/admin/file/download?filename=vm_{report_id}.csv"
        print(f"Downloading: {download_url}")

        time.sleep(2)

        csv_resp = page.request.get(download_url, headers=auth_headers)

        if not csv_resp.ok:
            print(f"ERROR: Download failed: {csv_resp.status} {csv_resp.status_text}")
            browser.close()
            sys.exit(1)

        csv_bytes = csv_resp.body()
        output_csv.write_bytes(csv_bytes)

        print(f"\n=========================================")
        print(f"Download complete")
        print(f"Output: {output_csv}")
        print(f"Size  : {len(csv_bytes)} bytes")
        print(f"=========================================")

        browser.close()


if __name__ == "__main__":
    run()