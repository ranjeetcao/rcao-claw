# Security Policy

## Supported Versions

Security fixes are applied to the `main` branch. There are no versioned releases yet.

| Branch | Supported |
|--------|-----------|
| `main` | Yes |

## Reporting a Vulnerability

If you discover a security vulnerability in zupee-claw, please report it responsibly. **Do not open a public GitHub issue for security vulnerabilities.**

### Preferred: GitHub Private Vulnerability Reporting

1. Go to the [Security tab](https://github.com/zupee-labs/zupee-claw/security) of this repository
2. Click **"Report a vulnerability"**
3. Fill out the form with the details described below

### Alternative: Email

If GitHub private reporting is unavailable, email **security@zupee.com** with the subject line: `[zupee-claw] Security Vulnerability Report`.

## What to Include

Please provide as much of the following as possible:

- **Description** — A clear summary of the vulnerability
- **Steps to reproduce** — Detailed steps to trigger the issue
- **Impact assessment** — What an attacker could achieve (e.g., container escape, host access, credential exposure)
- **Environment** — OS, Docker version, shell, and any relevant configuration
- **Affected files/components** — Which scripts, configs, or Docker files are involved
- **Suggested fix** (optional) — If you have a proposed remediation

## Scope

### In Scope

- Shell scripts (`setup.sh`, `cleanup.sh`, `bin/*`)
- Docker configuration (`docker/`)
- SSH and host configuration (`config/`)
- GitHub Actions workflows (`.github/workflows/`)
- Any mechanism that could lead to container escape, privilege escalation, or credential exposure

### Out of Scope

- Vulnerabilities in upstream dependencies (Docker Engine, OpenSSH, base images) — please report these to the respective projects
- Issues requiring physical access to the host machine
- Social engineering attacks

## Response Timeline

| Stage | Target |
|-------|--------|
| Acknowledgment | Within 48 hours |
| Initial assessment | Within 1 week |
| Fix or mitigation | Within 30 days (severity-dependent) |

We will keep you informed of progress throughout the process.

## Disclosure Policy

- We follow **coordinated disclosure** — please allow us reasonable time to address the issue before any public disclosure.
- We aim to release a fix before or simultaneously with any public announcement.

## Credit

We gratefully acknowledge security researchers who report vulnerabilities responsibly. With your permission, we will credit you in the release notes and/or CHANGELOG associated with the fix.

## Security-Critical Paths

The following paths contain security-sensitive code and are protected via [CODEOWNERS](.github/CODEOWNERS):

| Path | Sensitivity |
|------|-------------|
| `bin/` | Whitelisted host commands executed from containers |
| `config/` | SSH keys and configuration |
| `docker/` | Container definitions and permissions |
| `setup.sh` / `cleanup.sh` | System-level setup and teardown |
| `openclaw-home/` | Agent personality and LLM config (mounted `:ro`) |
| `.claude/rules/` | Security enforcement rules and pre-commit hooks |
