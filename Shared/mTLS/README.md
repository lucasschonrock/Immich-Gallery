# mTLS client certificate

tvOS has no Files picker, so the PKCS#12 has to be compiled into the app.

1. Copy your client certificate here as `client.p12`.
2. Either:
   - put the PKCS#12 password in `mtls-password.txt` (one line, no quotes), or
   - leave the password empty and enter it once in Settings → mTLS.
3. Rebuild and install the app.

Both files are gitignored. Without `client.p12`, the app uses ordinary TLS.
