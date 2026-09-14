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
import logging
import os
import traceback

from aiohttp import ClientSession
from blinkpy.blinkpy import Blink, BlinkTwoFARequiredError
from blinkpy.auth import Auth

CREDS = os.environ.get("BLINK_CREDS", "creds.json")
LOGFILE = os.environ.get("BLINK_LOGFILE", "login-debug.log")

# Full debug trace to a file the SIGMA session can read directly. Credentials are
# NEVER logged — only the flow and any errors. Delete login-debug.log when done.
logging.basicConfig(
    filename=LOGFILE,
    filemode="w",
    level=logging.DEBUG,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
_log = logging.getLogger("sigma-blink-login")


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
            _log.info("calling blink.start()")
            started = await blink.start()
            _log.info("blink.start() returned %r (no 2FA)", started)
        except BlinkTwoFARequiredError:
            _log.info("BlinkTwoFARequiredError raised — 2FA needed")
            print("\nBlink sent a 2-factor code to your phone/e-mail.")
            code = input("Enter the 2FA code: ").strip()
            if not code:
                print("\nNo code entered. Nothing saved. Re-run 1-LOGIN.cmd.")
                return
            _log.info("calling complete_2fa_login (code len=%d)", len(code))
            ok = await blink.auth.complete_2fa_login(code)
            _log.info("complete_2fa_login returned %r", ok)
            if not ok:
                print("\n*** 2FA verification FAILED ***")
                print("The code was wrong, expired, or already used. Nothing was saved.")
                print("Re-run 1-LOGIN.cmd and type the newest code quickly.")
                return
            # blinkpy's start() calls setup_urls() right after auth.startup(), but on
            # the 2FA path startup() raises BEFORE reaching it, so blink.urls stays
            # None and setup_post_verify() -> get_homescreen() crashes on urls.base_url.
            # complete_2fa_login has just populated auth.region_id via tier-info, so
            # build the urls now, exactly as the non-2FA path would have.
            _log.info("calling setup_urls() (region_id=%r)", getattr(blink.auth, "region_id", None))
            blink.setup_urls()
            _log.info("calling setup_post_verify()")
            started = await blink.setup_post_verify()
            _log.info("setup_post_verify() returned %r", started)

        # start() returns False on a bad e-mail/password (no exception). Do NOT
        # save a dead session — that would leave a creds.json that never works.
        if started is False:
            print("\n*** SIGN-IN FAILED ***")
            print("Blink rejected the e-mail or password (no 2-factor step was reached).")
            print("Check the e-mail and password are exactly your Blink/Amazon ones,")
            print("then re-run 1-LOGIN.cmd. Nothing was saved.")
            return

        _log.info("calling blink.refresh()")
        await blink.refresh()
        _log.info("refresh done; cameras=%r", sorted(blink.cameras))

        cams = sorted(blink.cameras)
        if cams:
            print("\nSigned in. Cameras found:")
            for name in cams:
                print("  -", name)
        else:
            print("\nSigned in, but Blink reported no cameras. Check they are "
                  "online in the Blink app, then run blink_helper.py anyway.")

        _log.info("calling blink.save(%s)", CREDS)
        await blink.save(CREDS)
        _log.info("save done; creds present=%s", os.path.exists(CREDS))
        print("\ncreds.json written to %s" % os.path.abspath(CREDS))
        print("Next: run  python blink_helper.py  (or double-click 2-START.cmd)")
    except Exception:
        _log.error("UNEXPECTED ERROR\n%s", traceback.format_exc())
        print("\n*** ERROR ***  Something failed after sign-in.")
        print("The full detail was written to %s — send that file to finish setup." % LOGFILE)
        traceback.print_exc()
    finally:
        await session.close()
        _log.info("session closed; run complete")


if __name__ == "__main__":
    asyncio.run(main())
