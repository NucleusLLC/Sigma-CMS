#!/usr/bin/env python3
"""
SIGMA-CMS · Blink helper — one-time sign-in  (blinkpy 0.25.x OAuth flow)
=======================================================================

Run this ONCE, interactively. It signs in to your Amazon/Blink account and
writes a session token to creds.json, so blink_helper.py can run unattended
afterwards.

Your Amazon e-mail, password and 2FA code are entered HERE, at your own
terminal. They are never sent to SIGMA and never stored in plain text by this
script (blinkpy writes only the resulting session token to creds.json).

    python login.py
"""

import asyncio
import getpass
import os

from aiohttp import ClientSession
from blinkpy.blinkpy import Blink, BlinkTwoFARequiredError
from blinkpy.auth import Auth

CREDS = os.environ.get("BLINK_CREDS", "creds.json")


async def main():
    email = input("Blink (Amazon) e-mail: ").strip()
    password = getpass.getpass("Blink (Amazon) password: ")

    session = ClientSession()
    try:
        blink = Blink(session=session)
        blink.auth = Auth(
            {"username": email, "password": password},
            no_prompt=True,
            session=session,
        )

        try:
            await blink.start()
        except BlinkTwoFARequiredError:
            # blinkpy 0.25.x: start() raises this once Blink has sent a code.
            code = input("2FA code Blink just sent you: ").strip()
            ok = await blink.auth.complete_2fa_login(code)
            if not ok:
                print("\n2FA verification failed. Re-run and check the code.")
                return
            await blink.setup_post_verify()

        await blink.refresh()

        cams = sorted(blink.cameras)
        if cams:
            print("\nSigned in. Cameras found:")
            for name in cams:
                print("  -", name)
        else:
            print("\nSigned in, but Blink reported no cameras. Check they are "
                  "online in the Blink app, then run blink_helper.py anyway.")

        await blink.save(CREDS)
        print("\ncreds.json written to %s" % os.path.abspath(CREDS))
        print("Next: run  python blink_helper.py  (or double-click 2-START.cmd)")
    finally:
        await session.close()


if __name__ == "__main__":
    asyncio.run(main())
