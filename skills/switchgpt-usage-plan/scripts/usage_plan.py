#!/usr/bin/env python3
"""Capture SwitchGPT quota and publish a local usage plan."""
import argparse
from collections import Counter
import fcntl
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid
from datetime import date, datetime, timezone


SKILL = Path(__file__).resolve().parent.parent
DEFAULT_DIR = Path.home() / "Library/Application Support/SwitchGPT-sly/UsagePlan"
TEMPLATE_MARKER = "__SWITCHGPT_PLAN_JSON__"


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def read_snapshot(path):
    snapshot = read_json(path)
    if type(snapshot.get("schemaVersion")) is not int or snapshot["schemaVersion"] != 1:
        raise ValueError("Unsupported account snapshot schema; file has been preserved")
    if not isinstance(snapshot.get("accounts"), list):
        raise ValueError("Account snapshot must contain an accounts list")
    emails = []
    for account in snapshot["accounts"]:
        if not isinstance(account, dict):
            raise ValueError("Invalid account snapshot entry")
        if account.get("email"):
            emails.append(account["email"].lower())
    if len(emails) != len(set(emails)):
        raise ValueError("Account snapshot contains duplicate emails")
    return snapshot


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("Expected a timestamp with a UTC offset")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.utcoffset() is None or "T" not in value:
        raise ValueError(f"Timestamp requires a time and UTC offset: {value}")
    return parsed


def select(source, keys):
    return {key: source[key] for key in keys if key in source}


def validate_expiry(value):
    if not isinstance(value, str) or date.fromisoformat(value).isoformat() != value:
        raise ValueError("Subscription expiry must be a real YYYY-MM-DD date")
    return value


def merge_subscriptions(snapshot, previous):
    accounts = {item["email"].lower(): item for item in snapshot["accounts"] if item.get("email")}
    for old in previous.get("accounts", []):
        subscription = old.get("subscription")
        if subscription is None:
            continue
        validate_expiry(subscription["expiresOn"])
        if subscription.get("source") != "manual":
            raise ValueError("Unknown subscription expiry source")
        timestamp(subscription["updatedAt"])
        email = old["email"]
        key = email.lower()
        if key not in accounts:
            accounts[key] = {"email": email, "displayName": email, "status": "unknown"}
            snapshot["accounts"].append(accounts[key])
        accounts[key]["subscription"] = subscription
    if previous.get("metadataUpdatedAt"):
        snapshot["metadataUpdatedAt"] = previous["metadataUpdatedAt"]
    snapshot["totalCount"] = len(snapshot["accounts"])
    snapshot["revision"] = str(uuid.uuid4())
    return snapshot


def set_expiry(snapshot, email, expires_on):
    if not isinstance(email, str) or len(email) > 320 or email != email.strip() or "@" not in email or any(ord(c) < 32 for c in email):
        raise ValueError("A valid saved account email is required")
    matches = [item for item in snapshot.get("accounts", []) if item.get("email", "").lower() == email.lower()]
    if len(matches) != 1:
        raise ValueError("Capture accounts first, then specify one matching account email")
    account = matches[0]
    updated_at = datetime.now(timezone.utc).isoformat()
    if expires_on is None:
        account.pop("subscription", None)
    else:
        account["subscription"] = {
            "expiresOn": validate_expiry(expires_on),
            "source": "manual",
            "updatedAt": updated_at,
        }
    snapshot["metadataUpdatedAt"] = updated_at
    snapshot["revision"] = str(uuid.uuid4())
    return snapshot


def capture():
    cli = shutil.which("switchgpt")
    if cli is None:
        candidates = (
            Path("/Applications/switchgpt-sly.app/Contents/Helpers/switchgpt"),
            Path.home() / ".local/bin/switchgpt",
            Path.home() / "Applications/switchgpt-sly.app/Contents/Helpers/switchgpt",
        )
        for candidate in candidates:
            cli = shutil.which(str(candidate))
            if cli is not None:
                break
    if cli is None:
        raise FileNotFoundError("Cannot find the SwitchGPT CLI. Install an app build that includes switchgpt.")
    # The CLI limits each account query. A single deadline here could cut off reports with many accounts.
    response = subprocess.run([cli, "quota"], check=True, capture_output=True)
    result = json.loads(response.stdout)
    if result.get("schemaVersion") != 1 or result.get("source") != "live":
        raise ValueError("Expected the SwitchGPT CLI v1 live quota report")
    timestamp(result["generatedAt"])
    snapshot = select(result, ("schemaVersion", "command", "source", "generatedAt", "totalCount", "partialCount", "errorCount"))
    snapshot["accounts"] = []
    for account in result["accounts"]:
        item = select(account, ("email", "displayName", "planName", "status", "refreshedAt"))
        if account.get("error"):
            item["error"] = select(account["error"], ("code",))
        quota = account.get("quota")
        if quota:
            item["quota"] = select(quota, ("creditsWereLoaded", "resetCreditsWereLoaded"))
            for key in ("weekly", "fiveHour"):
                if quota.get(key):
                    item["quota"][key] = select(quota[key], ("usedPercent", "remainingPercent", "resetAt"))
            if quota.get("credits") is not None:
                item["quota"]["credits"] = select(quota["credits"], ("points", "hasCredits", "unlimited"))
            if quota.get("resetCredits") is not None:
                cards = quota["resetCredits"]
                item["quota"]["resetCredits"] = select(cards, ("availableCount",))
                if isinstance(cards.get("credits"), list):
                    item["quota"]["resetCredits"]["credits"] = [
                        select(card, ("expiresAt",)) for card in cards["credits"]
                    ]
        snapshot["accounts"].append(item)
    return snapshot


def json_text(value):
    return json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n"


def atomic_write(path, content):
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as stream:
        temp = Path(stream.name)
        try:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
            temp.replace(path)
        finally:
            temp.unlink(missing_ok=True)


def validate_plan(plan, snapshot):
    if plan.get("schemaVersion") != 1 or plan.get("timeZone") != "Asia/Shanghai":
        raise ValueError("Expected plan schemaVersion 1 and timeZone Asia/Shanghai")
    for key in ("title", "summary"):
        if not isinstance(plan.get(key), str) or not plan[key].strip():
            raise ValueError(f"Plan requires {key}")
    generated_at = timestamp(plan["generatedAt"])
    observed_at = timestamp(snapshot["generatedAt"])
    if timestamp(plan["snapshotGeneratedAt"]) != observed_at or generated_at < observed_at:
        raise ValueError("Plan must refer to the latest account snapshot")
    if plan.get("snapshotRevision") != snapshot.get("revision"):
        raise ValueError("Account data or manual expiry changed; regenerate the plan")
    if snapshot.get("metadataUpdatedAt") and generated_at < timestamp(snapshot["metadataUpdatedAt"]):
        raise ValueError("Plan was generated before the latest manual expiry edit")
    budget = plan["budget"]
    if budget.get("currency") != "USD":
        raise ValueError("Budget currency must be USD")
    for key in ("monthlyLimit", "plannedTotal"):
        check_amount(budget[key])
    check_amount(budget.get("selfPayLimit", 0))
    if budget["plannedTotal"] > budget["monthlyLimit"] + budget.get("selfPayLimit", 0):
        raise ValueError("Plan exceeds the reimbursement and self-pay budget")
    accounts = {item["email"]: item for item in snapshot["accounts"] if item.get("email")}
    entries = plan["entries"]
    if not isinstance(entries, list):
        raise ValueError("Plan entries must be a list")
    previous_start = generated_at
    use_ends_at = generated_at
    conditional_use_started = False
    renewal_total = 0
    allocated_cards = Counter()
    for entry in entries:
        kind = entry["kind"]
        title = entry["title"]
        start = timestamp(entry["startAt"])
        if kind not in {"use", "card", "renew", "check"} or not isinstance(title, str) or not title.strip():
            raise ValueError("Each entry requires a supported kind and a title")
        if start < previous_start:
            raise ValueError(f"Entry is in the past or out of order: {title}")
        previous_start = start
        account = accounts.get(entry.get("account"))
        if (kind != "check" or "account" in entry) and account is None:
            raise ValueError(f"Entry requires a matching snapshot account: {title}")
        if account and " ".join(account.get("planName", "").split()).casefold() in {"plus", "chatgpt plus"}:
            raise ValueError(f"Plus accounts are excluded from usage plans: {title}")
        if kind in {"use", "card"} and account.get("status") not in {"ok", "partial"}:
            raise ValueError(f"Cannot schedule use or redemption for an unavailable account: {title}")
        if kind == "use":
            if conditional_use_started:
                raise ValueError("A conditional use segment must end before another use segment can be scheduled")
            if start < use_ends_at:
                raise ValueError(f"Use intervals must be positive and not overlap: {title}")
            if "endWhen" in entry:
                if "endAt" in entry or not isinstance(entry["endWhen"], str) or not entry["endWhen"].strip():
                    raise ValueError(f"Conditional use requires endWhen and no fixed endAt: {title}")
                conditional_use_started = True
            else:
                end = timestamp(entry["endAt"])
                if end <= start:
                    raise ValueError(f"Use intervals must be positive and not overlap: {title}")
                use_ends_at = end
            if entry.get("speed") not in {"standard", "fast", "as-needed"}:
                raise ValueError(f"Use entry requires a speed: {title}")
        elif "endAt" in entry or "endWhen" in entry:
            raise ValueError(f"Point actions cannot have use-segment end fields: {title}")
        if kind == "card":
            expiry = timestamp(entry["cardExpiresAt"])
            cards = account.get("quota", {}).get("resetCredits", {}).get("credits", [])
            known_expiries = Counter(timestamp(card["expiresAt"]) for card in cards if card.get("expiresAt"))
            if start >= expiry or expiry not in known_expiries:
                raise ValueError(f"Card must have a reported expiry after the checkpoint: {title}")
            allocation = (entry["account"], expiry)
            allocated_cards[allocation] += 1
            if allocated_cards[allocation] > known_expiries[expiry]:
                raise ValueError(f"Card is allocated more than the reported inventory: {title}")
        if kind == "renew":
            amount = entry["amountUsd"]
            check_amount(amount)
            renewal_total += amount
    if not math.isclose(renewal_total, budget["plannedTotal"], abs_tol=0.001):
        raise ValueError("Budget plannedTotal must equal the renewal entries")


def check_amount(amount):
    if type(amount) not in (int, float) or not math.isfinite(amount) or amount < 0:
        raise ValueError("USD amounts must be finite non-negative numbers")


def publish(plan, snapshot, folder):
    validate_plan(plan, snapshot)
    template = (SKILL / "assets/usage-plan.html").read_text(encoding="utf-8")
    if template.count(TEMPLATE_MARKER) != 1:
        raise ValueError("HTML template requires one JSON marker")
    payload = json_text({"demo": False, "snapshot": snapshot, "plan": plan})
    payload = payload.replace("&", "\\u0026").replace("<", "\\u003c").replace(">", "\\u003e")
    page = template.replace(TEMPLATE_MARKER, payload)
    outputs = {folder / "usage-plan.json": json_text(plan), folder / "usage-plan.html": page}
    previous = {path: path.read_text(encoding="utf-8") if path.exists() else None for path in outputs}
    try:
        for path, content in outputs.items():
            atomic_write(path, content)
    except OSError:
        for path, content in previous.items():
            if content is None:
                path.unlink(missing_ok=True)
            else:
                atomic_write(path, content)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=DEFAULT_DIR)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("capture", help="query current accounts and save account-state.json")
    save = commands.add_parser("publish", help="validate a draft and publish the plan and HTML")
    save.add_argument("draft", type=Path)
    expiry = commands.add_parser("set-expiry", help="edit the canonical manual subscription date")
    expiry.add_argument("email")
    choice = expiry.add_mutually_exclusive_group(required=True)
    choice.add_argument("--date", dest="expires_on")
    choice.add_argument("--clear", action="store_true")
    args = parser.parse_args()
    folder = args.directory.expanduser().resolve()
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = folder / "account-state.json"
    snapshot = capture() if args.action == "capture" else None
    with (folder / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == "capture":
            previous = read_snapshot(path) if path.exists() else {}
            if previous.get("generatedAt") and timestamp(previous["generatedAt"]) > timestamp(snapshot["generatedAt"]):
                print(f"Kept newer snapshot: {path}")
            else:
                atomic_write(path, json_text(merge_subscriptions(snapshot, previous)))
                print(path)
        elif args.action == "set-expiry":
            atomic_write(path, json_text(set_expiry(read_snapshot(path), args.email, args.expires_on)))
            print(path)
        else:
            publish(read_json(args.draft), read_snapshot(path), folder)
            print(folder / "usage-plan.json")
            print(folder / "usage-plan.html")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"usage-plan: {error}", file=sys.stderr)
        raise SystemExit(1)
