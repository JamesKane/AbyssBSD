#!/bin/sh
# AbyssBSD Swift DE — TLS, verified or refused (PHASE18 P18.12a).
#
# The client is ours (abyss-model fetch, over CTLS and the base system's
# OpenSSL); the server is not: `openssl s_server`, with certificates this test
# makes. Claims:
#
#   1. a server whose certificate chains to the trusted CA and names the host
#      is fetched: status 200 and its page;
#   2. the same server, without that CA trusted, is refused: the certificate
#      does not verify, and nothing is fetched;
#   3. a certificate the CA signed for another name is refused: it does not
#      name the host;
#   4. plain http still works, against a server that is not ours (nc).
#
# Usage: abyss/tests/live-tls.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
bin="$root/.build/debug/abyss-model"
[ -x "$bin" ] || swift build --product abyss-model
command -v openssl >/dev/null || { echo "FAIL: openssl not installed — it is the server"; exit 1; }

W=$(mktemp -d /tmp/abyss-tls.XXXXXX)
cleanup() { for p in ${s1:-} ${s2:-} ${np:-}; do kill "$p" 2>/dev/null || true; done; rm -rf "$W"; }
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }

# A CA, a certificate for localhost, and one for another name — both the CA's.
cd "$W"
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 1 -subj "/CN=AbyssBSD test CA" >/dev/null 2>&1
for name in localhost other.example; do
  openssl req -newkey rsa:2048 -nodes -keyout "$name.key" -out "$name.csr" -subj "/CN=$name" >/dev/null 2>&1
  printf 'subjectAltName=DNS:%s\n' "$name" > "$name.ext"
  openssl x509 -req -in "$name.csr" -CA ca.pem -CAkey ca.key -CAcreateserial -out "$name.pem" -days 1 -extfile "$name.ext" >/dev/null 2>&1
done
cd "$root"
port1=$((20000 + $$ % 10000)); port2=$((port1 + 1))
openssl s_server -accept "$port1" -cert "$W/localhost.pem" -key "$W/localhost.key" -www -quiet > "$W/s1.log" 2>&1 & s1=$!
openssl s_server -accept "$port2" -cert "$W/other.example.pem" -key "$W/other.example.key" -www -quiet > "$W/s2.log" 2>&1 & s2=$!
sleep 1

# ---- 1. verified --------------------------------------------------------------
"$bin" fetch "https://localhost:$port1/" --ca "$W/ca.pem" > "$W/f1" 2>&1 || fail "the verified fetch failed: $(cat "$W/f1")"
head -1 "$W/f1" | grep -q '^status 200$' || fail "not a 200: $(head -3 "$W/f1")"
grep -q 's_server' "$W/f1" || fail "not the server's page: $(head -c 300 "$W/f1")"
echo "ok: 1. a certificate from the trusted CA, naming the host: fetched (200, s_server's page)"

# ---- 2. an untrusted CA ------------------------------------------------------------
"$bin" fetch "https://localhost:$port1/" > "$W/f2" 2>&1 && fail "a certificate from an untrusted CA was accepted"
grep -qi 'certificate' "$W/f2" || fail "the refusal does not say why: $(cat "$W/f2")"
echo "ok: 2. without the CA trusted, refused: $(sed 's/^abyss-model: //' "$W/f2" | cut -c1-120)"

# ---- 3. another name ------------------------------------------------------------------
"$bin" fetch "https://localhost:$port2/" --ca "$W/ca.pem" > "$W/f3" 2>&1 && fail "a certificate for another name was accepted"
grep -qi 'hostname mismatch' "$W/f3" || fail "the refusal does not say the name is wrong: $(cat "$W/f3")"
echo "ok: 3. a trusted certificate for another name, refused: hostname mismatch"

# ---- 4. plain http ----------------------------------------------------------------------
port3=$((port1 + 2))
printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nplain and simple\n' > "$W/plain.http"
if nc -h 2>&1 | grep -q Ncat; then o=; else o=-N; fi
nc -l $o 127.0.0.1 "$port3" < "$W/plain.http" > "$W/nc.req" 2>/dev/null & np=$!
sleep 0.3
"$bin" fetch "http://127.0.0.1:$port3/x" > "$W/f4" 2>&1 || fail "plain http failed: $(cat "$W/f4")"
grep -q 'plain and simple' "$W/f4" || fail "plain http's body: $(cat "$W/f4")"
head -1 "$W/nc.req" | grep -q '^GET /x HTTP/1.0' || fail "the request was not HTTP/1.0: $(head -1 "$W/nc.req")"
echo "ok: 4. plain http, as HTTP/1.0 (a body the server ends by closing, never chunked)"
echo "all green (TLS verified against a trusted CA and the host's name, or refused with why)."
