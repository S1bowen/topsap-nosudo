#!/usr/bin/env python3
"""Build TopSAP engine request JSON.

Field types and credential encoding are taken from the shipped Electron client
(vone/pub/common/scripts/sv_init.js) and were verified against the real
libtopsec_vpn.so: every port/proxy/protocol field must be a JSON *string*
(they get strcmp/atoi'd on the C side) and the switch fields are "on"/"off".

    user = encodeURIComponent(base64(utf8(username)))
    pwd  = base64(RSA-PKCS1-v1.5(password, PUBLIC_KEY))   with '+' -> '%2B'

Both are reproduced here with a small hand-rolled DER parser, so no crypto
library is needed.  Passwords are read from stdin ('-') so they never appear
in argv.
"""
import base64
import json
import sys
from urllib.parse import quote

# RSA public key shipped in the client (vone/pub/common/scripts/sv_init.js).
PUBLIC_KEY = (
    "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCq0GDTn2LRnHkCceiKG7cLo5V/JH5Q0huwbLMAkVa2"
    "GzbwD7W5X7hmOVrT5xtju74k+J8/ltvhlS6vGNqew6RAU52M/t5+uWJ+RkRuS0yhhw58SsZaxybpgwkj"
    "FopHDc8Z7lsweVhzNSdsKoDZnZLQR9fXIw7oTamg+Ifz+BIeYwIDAQAB"
)


def die(m):
    sys.exit("svmk.py: " + m)


# ------------------------------------------------------------------ DER / RSA

def _der(buf, off):
    tag = buf[off]
    off += 1
    ln = buf[off]
    off += 1
    if ln & 0x80:
        n = ln & 0x7F
        ln = int.from_bytes(buf[off:off + n], "big")
        off += n
    return tag, off, ln, off + ln


def _int(buf, off):
    tag, s, ln, nxt = _der(buf, off)
    if tag != 0x02:
        raise ValueError("expected INTEGER, tag 0x%02x" % tag)
    return int.from_bytes(buf[s:s + ln], "big"), nxt


def parse_spki(b64):
    """SubjectPublicKeyInfo -> (n, e)."""
    buf = base64.b64decode(b64 + "=" * (-len(b64) % 4))
    tag, s, ln, _ = _der(buf, 0)
    if tag != 0x30:
        raise ValueError("expected SPKI SEQUENCE")
    tag, s2, ln2, nxt2 = _der(buf, s)            # AlgorithmIdentifier
    tag, s3, ln3, nxt3 = _der(buf, nxt2)         # BIT STRING
    if tag != 0x03 or buf[s3] != 0x00:
        raise ValueError("unexpected BIT STRING")
    tag, s4, ln4, _ = _der(buf, s3 + 1)          # RSAPublicKey
    n, o = _int(buf, s4)
    e, o = _int(buf, o)
    return n, e


def rsa_encrypt_pkcs1(msg, n, e):
    k = (n.bit_length() + 7) // 8
    m = msg if isinstance(msg, bytes) else msg.encode()
    if len(m) > k - 11:
        raise ValueError("password too long for %d-bit key" % n.bit_length())
    em = b"\x00\x02" + b"\xff" * (k - 3 - len(m)) + b"\x00" + m
    return base64.b64encode(pow(int.from_bytes(em, "big"), e, n).to_bytes(k, "big")).decode()


def user_field(username):
    """encodeURIComponent(base64(utf8(username)))."""
    return quote(base64.b64encode(username.encode()).decode(), safe="")


def pwd_field(password):
    """base64(RSA-PKCS1v15(password)) with '+' escaped, exactly as the client."""
    n, e = parse_spki(PUBLIC_KEY)
    return rsa_encrypt_pkcs1(password, n, e).replace("+", "%2B")


# ------------------------------------------------------------------- payloads

def _proxy_block(p=None):
    p = p or {}
    return {
        "type": str(p.get("type", "0")),
        "addr": str(p.get("addr", "")),
        "port": str(p.get("port", "0")),
        "user": str(p.get("user", "")),
        "pwd": str(p.get("pwd", "")),
        "domain": str(p.get("domain", "")),
    }


def _auth_block(a=None):
    """Auth parameters as returned by get_auth_param; all strings."""
    a = a or {}
    return {
        "vpn_version": str(a.get("vpn_version", "")),
        "auth_protocol": str(a.get("auth_protocol", "0")),
        "auth_port": str(a.get("auth_port", "")),
        "data_port": str(a.get("data_port", "")),
        "data_protocol": str(a.get("data_protocol", "0")),
        "cert_type": str(a.get("cert_type", "0")),
    }


def build_authparam(host, port, user, pwd, proxy=None):
    p = _proxy_block(proxy)
    return {
        "method": "get_auth_param",
        "serverAddr": str(host),
        "serverPort": str(port),
        "proxyType": p["type"],
        "proxyAddr": p["addr"],
        "proxyPort": p["port"],
        "proxyUser": p["user"],
        "proxyPwd": p["pwd"],
        "proxyDomain": p["domain"],
        "user": user_field(user),
        "pwd": pwd_field(pwd),
        "_flag": 1,
    }


def build_login(host, port, user, pwd, auth=None):
    req = {
        "method": "login_by_pwd",
        "vone": {"addr": str(host), "port": str(port),
                 "user": user_field(user), "pwd": pwd_field(pwd), "_flag": 1},
        "proxy": _proxy_block(None),
        "remember_pwd": "off",
        "auto_login": "off",
    }
    req.update(_auth_block(auth))
    a = auth or {}
    # gid block is only sent when the gateway demands a captcha
    if str(a.get("login_check_verify", "")).lower() in ("true", "yes"):
        req["gid"] = {"cgid": str(a.get("cgid", "")), "gid": str(a.get("gid_captcha", ""))}
    return req


def build_chk_sms(code, auth=None, flag="otp"):
    """Second-factor submission.

    The GUI's submit_google_code() sends exactly this shape (sv_init.js):
    an OTP is a "sms" with flag "otp"; sms is only used when the gateway
    offers SMS instead of an authenticator app.
    """
    req = {
        "method": "chk_sms",
        "ctx_id": " ",
        "Challenge_state": " ",
        "topsecsvaaa": " ",
        "topsecsvccc": " ",
        "topsecsvddd": " ",
        "sms": str(code),
        "flag": str(flag),
    }
    req.update(_auth_block(auth))
    return req


def build_sms(host, port, user, code, auth=None, send=False):
    a = auth or {}
    req = {
        "method": "send_sms" if send else "login_by_sms",
        "vone": {"addr": str(host), "port": str(port),
                 "user": user_field(user), "U": quote(user, safe="")},
    }
    if not send:
        req["new_sms"] = str(code)
    req.update(_auth_block(a))
    if str(a.get("login_check_verify", "")).lower() in ("true", "yes"):
        req["gid"] = {"cgid": str(a.get("cgid", "")), "gid": str(a.get("gid_captcha", ""))}
    return req


# ----------------------------------------------------------------------- main

def _pwd_from_stdin():
    return sys.stdin.read().rstrip("\n")


def _load_auth(arg):
    if not arg or arg == "-":
        return {}
    if arg.lstrip().startswith("{"):
        return json.loads(arg)
    with open(arg) as fh:
        return json.load(fh)


def main():
    a = sys.argv[1:]
    if not a:
        die("usage: svmk.py authparam|login|sms|sendsms ... | svmk.py METHOD [json] | svmk.py raw JSON")
    m = a[0]

    if m == "authparam":
        if len(a) < 4:
            die("usage: svmk.py authparam HOST PORT USER   (password on stdin)")
        req = build_authparam(a[1], a[2], a[3], _pwd_from_stdin(),
                              json.loads(a[4]) if len(a) > 4 else None)
    elif m == "login":
        if len(a) < 4:
            die("usage: svmk.py login HOST PORT USER [AUTHPARAM_JSON|-]   (password on stdin)")
        req = build_login(a[1], a[2], a[3], _pwd_from_stdin(), _load_auth(a[4] if len(a) > 4 else None))
    elif m == "otp":
        if len(a) < 2:
            die("usage: svmk.py otp CODE [AUTHPARAM_JSON|-]   (google-authenticator code)")
        req = build_chk_sms(a[1], _load_auth(a[2] if len(a) > 2 else None))
    elif m == "sms":
        if len(a) < 5:
            die("usage: svmk.py sms HOST PORT USER CODE [AUTHPARAM_JSON|-]")
        req = build_sms(a[1], a[2], a[3], a[4], _load_auth(a[5] if len(a) > 5 else None))
    elif m == "sendsms":
        if len(a) < 4:
            die("usage: svmk.py sendsms HOST PORT USER [AUTHPARAM_JSON|-]")
        req = build_sms(a[1], a[2], a[3], "", _load_auth(a[4] if len(a) > 4 else None), send=True)
    elif m == "raw":
        if len(a) < 2:
            die("raw needs a JSON argument")
        print(a[1])
        return
    else:
        req = {"method": m}
        if len(a) > 1:
            req.update(json.loads(a[1]))

    print(json.dumps(req))


main()
