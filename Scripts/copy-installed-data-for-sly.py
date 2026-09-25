#!/usr/bin/env python3
"""Copy the installed app's local accounts into the isolated sly app directory.

This never prints authentication contents and refuses to overwrite an existing sly profile.
"""

import json
import os
import pathlib
import shutil
import stat
import uuid


support = pathlib.Path.home() / "Library" / "Application Support"
source = support / "SwitchGPT"
destination = support / "SwitchGPT-sly"
staging = support / (".SwitchGPT-sly-" + uuid.uuid4().hex + ".tmp")


def require_private_directory(path: pathlib.Path) -> None:
    details = path.lstat()
    if not stat.S_ISDIR(details.st_mode) or details.st_uid != os.geteuid():
        raise ValueError("A source directory is not a private local directory")
    if stat.S_IMODE(details.st_mode) & 0o077:
        raise ValueError("A source directory grants access to another user")


def copy_private_file(source_file: pathlib.Path, target_file: pathlib.Path) -> None:
    details = source_file.lstat()
    if not stat.S_ISREG(details.st_mode) or details.st_uid != os.geteuid():
        raise ValueError("A source file is not a private regular file")
    if stat.S_IMODE(details.st_mode) & 0o077:
        raise ValueError("A source file grants access to another user")
    descriptor = os.open(source_file, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        with os.fdopen(descriptor, "rb") as input_file:
            with target_file.open("xb") as output_file:
                os.chmod(target_file, 0o600)
                shutil.copyfileobj(input_file, output_file)
    except BaseException:
        target_file.unlink(missing_ok=True)
        raise


def main() -> None:
    if destination.exists() or destination.is_symlink():
        raise FileExistsError("The sly data directory already exists; no data was overwritten")
    require_private_directory(source)
    require_private_directory(source / "Accounts")
    require_private_directory(source / "Transactions")
    if any((source / "Transactions").iterdir()):
        raise ValueError("An unfinished switch transaction exists; copy was stopped")

    state_file = source / "preview-state.json"
    state_details = state_file.lstat()
    if (not stat.S_ISREG(state_details.st_mode)
            or state_details.st_uid != os.geteuid()
            or stat.S_IMODE(state_details.st_mode) & 0o077):
        raise ValueError("The account index is not a private regular file")
    with state_file.open("r", encoding="utf-8") as input_file:
        state = json.load(input_file)
    if state.get("schemaVersion") != 1 or not isinstance(state.get("accounts"), list):
        raise ValueError("The account index schema is not supported")

    staging.mkdir(mode=0o700)
    try:
        (staging / "Accounts").mkdir(mode=0o700)
        (staging / "Transactions").mkdir(mode=0o700)
        copied = set()
        for account in state["accounts"]:
            account_source = account.get("source", {}).get("codexHome", {})
            old_path = pathlib.Path(account_source.get("path", ""))
            if old_path.parent != source / "Accounts":
                raise ValueError("An account path is outside the installed app's account storage")
            uuid.UUID(old_path.name)
            if old_path.name in copied:
                raise ValueError("Two accounts refer to the same local directory")
            copied.add(old_path.name)
            require_private_directory(old_path)
            new_path = staging / "Accounts" / old_path.name
            new_path.mkdir(mode=0o700)
            copy_private_file(old_path / "auth.json", new_path / "auth.json")
            (new_path / "log").mkdir(mode=0o700)
            (new_path / "tmp").mkdir(mode=0o700)
            account_source["path"] = str(destination / "Accounts" / old_path.name)

        receipts = source / "SwitchReceipts"
        receipt_count = 0
        if receipts.exists():
            require_private_directory(receipts)
            target_receipts = staging / "SwitchReceipts"
            target_receipts.mkdir(mode=0o700)
            for receipt in receipts.iterdir():
                if receipt.suffix != ".json":
                    raise ValueError("An unexpected receipt file was found")
                uuid.UUID(receipt.stem)
                copy_private_file(receipt, target_receipts / receipt.name)
                receipt_count += 1

        target_state = staging / "preview-state.json"
        with target_state.open("x", encoding="utf-8") as output_file:
            os.chmod(target_state, 0o600)
            json.dump(state, output_file, ensure_ascii=False, sort_keys=True)
        os.rename(staging, destination)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    print(f"Copied {len(copied)} accounts and {receipt_count} receipts to {destination}")


if __name__ == "__main__":
    main()
