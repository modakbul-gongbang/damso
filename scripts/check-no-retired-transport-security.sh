#!/bin/bash
# ADR 0003 / AC4: the retired transport-security stack must stay gone.
#
# Deleting the certificate, the pinning delegate, and the Keychain wrapper is
# only half the decision - the other half is that none of it quietly comes
# back, and a build that merely compiles proves nothing about absence. This is
# the executable half, run as part of `make verify-static`.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail=0
report() {
  echo "FAIL: $1"
  fail=1
}

# The deleted files themselves.
for path in \
  Sources/Damso/Core/TLSPinning.swift \
  Sources/Damso/Core/SecretStore.swift \
  Tests/DamsoTests/TLSPinningTests.swift
do
  [[ -e "$path" ]] && report "$path is back; ADR 0003 removed it"
done

# The client's TLS-pinning and Keychain symbols. Scoped to Sources/ and
# Tests/ so an ADR or README explaining what was removed is not a violation.
if grep -rn -E "PinnedCertificateSessionDelegate|TrustOnFirstUseSessionDelegate|certificateFingerprint|probedFingerprint" Sources Tests --include="*.swift" >/dev/null; then
  report "certificate-pinning symbols still exist in Swift sources:"
  grep -rn -E "PinnedCertificateSessionDelegate|TrustOnFirstUseSessionDelegate|certificateFingerprint|probedFingerprint" Sources Tests --include="*.swift"
fi

if grep -rn -E "SecItemAdd|SecItemCopyMatching|kSecClassGenericPassword|KeychainSecretStore" Sources Tests --include="*.swift" >/dev/null; then
  report "Keychain access is back in Swift sources:"
  grep -rn -E "SecItemAdd|SecItemCopyMatching|kSecClassGenericPassword|KeychainSecretStore" Sources Tests --include="*.swift"
fi

# The server transport must not dial https. Scoped to the files that build
# server URLs - an unrelated https reference elsewhere (the Plaud CLI's own
# login flow, for instance) is not this decision's business.
transport_sources=(
  Sources/Damso/Core/DamsoHTTPClient.swift
  Sources/Damso/Core/ServerConnection.swift
  Sources/Damso/Core/LocalServerLifecycle.swift
  Sources/Damso/RemoteExecutionSettingsView.swift
)
if grep -n "https://" "${transport_sources[@]}" >/dev/null; then
  report "the server transport still builds an https:// URL:"
  grep -n "https://" "${transport_sources[@]}"
fi

# Server-side certificate generation and its dependency.
if grep -rn -E "ssl_certfile|ssl_keyfile|x509|cryptography" backend/damso --include="*.py" >/dev/null; then
  report "server still references TLS/certificate machinery:"
  grep -rn -E "ssl_certfile|ssl_keyfile|x509|cryptography" backend/damso --include="*.py"
fi

if grep -n "cryptography" pyproject.toml >/dev/null; then
  report "pyproject.toml still declares the cryptography dependency"
fi

if [[ "$fail" -eq 0 ]]; then
  echo "OK: retired transport-security stack (self-signed TLS, fingerprint pinning, Keychain) is absent."
fi
exit "$fail"
