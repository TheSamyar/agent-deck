# Security

Do not post secrets or exploitable approval-routing failures in public issues. Report vulnerabilities privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability** (private vulnerability reporting). Do not include exploit details in public issues.

Include the affected revision, macOS version, provider/host, expected behavior, and a minimal reproduction using disposable data.

## Trust boundary

The native runtime uses authenticated loopback HTTP and a current-user Unix socket. It does not isolate malicious processes running as the same macOS user. Approval controls must remain tied to the original request and session; stale, repeated, expired, and disconnected requests must fail closed.

Only the current native preview receives fixes. It has not completed stable-release certification. See docs/NATIVE.md for data retention and transport details.
