#!/usr/bin/env python3
"""
SIGMA-CMS · Blink helper — one-time sign-in
===========================================

Run this ONCE, interactively. It signs in to your Amazon/Blink account and
writes a session token to creds.json, so blink_helper.py can run unattended
afterwards.

Your Amazon e-mail, password and 2FA code are entered HERE, at your own
terminal. They are never sent to SIGMA, never stored in plain text by this
script (blinkpy writes only the resulting session token), and never leave your
machine except to Amazon's own login endpoint.

    python login.py

You will be asked for:
  - your Blink (Amazon) e-mail
  - your Blink (Amazon) password
  - the 2FA code Blink texts/e-mails you

When it prints "creds.json written", start the helper:  python blink_helper.py
"""

import asyncio
import getpass
import os

from blinkpy.blinkpy import Blink
from blinkpy.auth import Auth

CREDS = os.environ.get("BLINK_CREDS", "creds.json")


async def main():
    email = input("Blink (Amazon) e-mail: ").strip()
    password = getpass.getpass("Blink (Amazon) password: ")

    blink = Blink()
    blink.auth = Auth({"username": email, "password": password}, no_prompt=True)
    await blink.start()

    # start() flags when a 2FA key is required.
    if blink.auth.check_key_required():
        code = input("2FA code Blink just sent you: ").strip()
        await blink.auth.send_auth_key(blink, code)
        await blink.setup_post_verify()

    await blink.refresh()
    print("\nSigned in. Cameras found:")
    for name in sorted(blink.cameras):
        print("  -", name)

    await blink.save(CREDS)
    print("\ncreds.json written to %s" % os.path.abspath(CREDS))
    print("Now run:  python blink_helper.py")


if __name__ == "__main__":
    asyncio.run(main())
