#!/usr/bin/env python3
"""Make a presigned GET URL for an object in a private Cloudflare R2 bucket.

The credentials come from the CLOUDFLARE_API_TOKEN environment variable, the
same variable the Cloudflare Terraform provider reads. The token needs read
access to the bucket. The R2 S3 credentials are derived from the token: the
access key ID is the token ID (looked up with the Cloudflare API), and the
secret access key is the SHA-256 hash of the token value.

Usage:
  r2-presign.py s3://<bucket>/<key> <account-id> [<expires-seconds>]
      Print the URL.
  r2-presign.py
      Terraform `external` data source protocol: read {"url", "account_id",
      "expires"} as JSON on stdin, write {"url": ...} as JSON on stdout.

Only the Python standard library is used. Signing is SigV4 query
authentication with path-style addressing, the same as `aws s3 presign`.
"""
import datetime
import hashlib
import hmac
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.cloudflare.com/client/v4"
DEFAULT_EXPIRES = 86400  # SigV4 maximum is 604800


def fail(msg):
    print(f"r2-presign: {msg}", file=sys.stderr)
    sys.exit(1)


def token_id(token, account_id):
    # User tokens verify at /user/tokens/verify; account-owned tokens only at
    # /accounts/<id>/tokens/verify.
    errors = []
    for path in ("/user/tokens/verify", f"/accounts/{account_id}/tokens/verify"):
        req = urllib.request.Request(API + path, headers={"Authorization": f"Bearer {token}"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = json.load(resp)
        except urllib.error.HTTPError as e:
            errors.append(f"{path}: HTTP {e.code}")
            continue
        except (urllib.error.URLError, OSError, ValueError) as e:
            fail(f"Cloudflare API request {path} failed: {e}")
        result = body.get("result") or {}
        if body.get("success") and result.get("id"):
            if result.get("status") != "active":
                fail(f"CLOUDFLARE_API_TOKEN is not active (status: {result.get('status')})")
            return result["id"]
        errors.append(f"{path}: {body.get('errors')}")
    fail("could not verify CLOUDFLARE_API_TOKEN: " + "; ".join(errors))


def presign(url, account_id, expires):
    src = urllib.parse.urlparse(url)
    if src.scheme != "s3" or not src.netloc or src.path in ("", "/"):
        fail(f"expected s3://<bucket>/<key>, got {url!r}")
    if not account_id:
        fail("the Cloudflare account ID is empty")
    if not 1 <= expires <= 604800:
        fail(f"expires must be 1..604800 seconds, got {expires}")
    token = os.environ.get("CLOUDFLARE_API_TOKEN", "").strip()
    if not token:
        fail("CLOUDFLARE_API_TOKEN is not set; it is needed to sign s3:// URLs")

    access_key_id = token_id(token, account_id)
    secret_access_key = hashlib.sha256(token.encode()).hexdigest()

    host = f"{account_id}.r2.cloudflarestorage.com"
    region = "auto"
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    scope = f"{day}/{region}/s3/aws4_request"
    path = urllib.parse.quote(f"/{src.netloc}{src.path}", safe="/~")
    params = {
        "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
        "X-Amz-Credential": f"{access_key_id}/{scope}",
        "X-Amz-Date": amz_date,
        "X-Amz-Expires": str(expires),
        "X-Amz-SignedHeaders": "host",
    }
    query = "&".join(f"{k}={urllib.parse.quote(v, safe='~')}" for k, v in sorted(params.items()))
    canonical_request = f"GET\n{path}\n{query}\nhost:{host}\n\nhost\nUNSIGNED-PAYLOAD"
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256", amz_date, scope,
        hashlib.sha256(canonical_request.encode()).hexdigest(),
    ])
    key = ("AWS4" + secret_access_key).encode()
    for part in (day, region, "s3", "aws4_request"):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    signature = hmac.new(key, string_to_sign.encode(), hashlib.sha256).hexdigest()
    return f"https://{host}{path}?{query}&X-Amz-Signature={signature}"


def main():
    args = sys.argv[1:]
    if args:
        if len(args) not in (2, 3):
            fail("usage: r2-presign.py s3://<bucket>/<key> <account-id> [<expires-seconds>]")
        expires = int(args[2]) if len(args) == 3 else DEFAULT_EXPIRES
        print(presign(args[0], args[1], expires))
        return
    try:
        query = json.load(sys.stdin)
        expires = int(query.get("expires") or DEFAULT_EXPIRES)
    except (ValueError, TypeError) as e:
        fail(f"bad query on stdin: {e}")
    json.dump({"url": presign(query.get("url", ""), query.get("account_id", ""), expires)}, sys.stdout)


if __name__ == "__main__":
    main()
