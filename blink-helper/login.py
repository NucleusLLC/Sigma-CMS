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

        started = None
        try:
            started = await blink.start()
        except BlinkTwoFARequiredError:
            # blinkpy 0.25.x: start() raises this once Blink has sent a code.
            print("\nBlink sent a 2-factor code to your phone/e-mail.")
            code = input("Enter the 2FA code: ").strip()
            if not code:
                print("\nNo code entered. Nothing saved. Re-run 1-LOGIN.cmd.")
                return
            ok = await blink.auth.complete_2fa_login(code)
            if not ok:
                print("\n*** 2FA verification FAILED ***")
                print("The code was wrong, expired, or already used. Nothing was saved.")
                print("Re-run 1-LOGIN.cmd and type the newest code quickly.")
                return
            started = await blink.setup_post_verify()

        # start() returns False on a bad e-mail/password (no exception). Do NOT
        # save a dead session — that would leave a creds.json that never works.
        if started is False:
            print("\n*** SIGN-IN FAILED ***")
            print("Blink rejected the e-mail or password (no 2-factor step was reached).")
            print("Check the e-mail and password are exactly your Blink/Amazon ones,")
            print("then re-run 1-LOGIN.cmd. Nothing was saved.")
            return

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
