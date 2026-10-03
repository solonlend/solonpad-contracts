# Key plumbing shared by script/v3/{mainnet,fork,testnet}/lib.sh (sourced; the caller defines `pk ROLE` -> raw key on
# stdout, and `die`). Raw private keys never enter a process argv (ps / /proc/<pid>/cmdline are readable by every
# local user — review finding #1); a key only travels through a pipe or an exported variable of our own processes.
#   with_key ROLE CMD...  run CMD (cast / forge create / cast wallet sign) with ETH_KEYSTORE + ETH_PASSWORD (foundry's
#                         --keystore / --password-file env) pointing at a one-shot keystore: 0700 temp dir, 0600
#                         files, random password, deleted as soon as CMD returns.
#   key_env ROLE          export DEPLOYER_PRIVATE_KEY for forge script (use inside a subshell).
#   key_addr ROLE         address of ROLE's key.
_KS_PY='
import json, os, secrets, sys
from eth_account import Account
k = sys.stdin.read().strip()
if not k: sys.exit("no key")
pw = secrets.token_hex(32)
# The KDF is not the protection here (the password sits next to it); the 0700 dir and its deletion are. Cheap N.
ks = Account.encrypt(k, pw, kdf="scrypt", iterations=1 << 12)
for path, data in ((sys.argv[2], pw), (sys.argv[1], json.dumps(ks))):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(fd, data.encode()); os.close(fd)
'
with_key() {
  local role=$1 d rc=0; shift
  d=$(mktemp -d "${TMPDIR:-/tmp}/solon-ks.XXXXXX") || die "mktemp failed"
  chmod 700 "$d"
  pk "$role" | python3 -c "$_KS_PY" "$d/k.json" "$d/pw" || { rm -rf "$d"; die "keystore for $role failed"; }
  ETH_KEYSTORE="$d/k.json" ETH_PASSWORD="$d/pw" "$@" || rc=$?
  rm -rf "$d"
  return $rc
}
key_env() { DEPLOYER_PRIVATE_KEY=$(pk "$1") || die "no key for $1"; export DEPLOYER_PRIVATE_KEY; }
key_addr() { pk "$1" | python3 -c 'import sys; from eth_account import Account; print(Account.from_key(sys.stdin.read().strip()).address)'; }
