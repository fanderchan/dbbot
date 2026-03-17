# Security Policy

## Supported Versions

Security reports are investigated against:

- the latest GitHub release
- the current `main` branch when no formal release exists yet

## Reporting a Vulnerability

Do not open a public issue with credentials, raw inventory files, private hostnames, private IP addresses, exploit details, or database dumps.

Preferred path:

1. Use GitHub private vulnerability reporting for this repository if it is enabled.
2. If private reporting is not available, open a public issue without sensitive details and ask the maintainer to move the conversation to a private channel before sharing evidence.

## Sensitive Data Handling

When reporting a problem, always redact:

- passwords, tokens, SSH keys, and certificates
- raw inventory files and host-specific secrets
- customer names, private hostnames, and internal IP addresses when they are not required to explain the issue
- database dumps or other production data

## Scope

This project automates deployment, backup, restore, and monitoring flows. Reports involving credential handling, unsafe defaults, privilege escalation, destructive restore behavior, or data exposure are in scope.
