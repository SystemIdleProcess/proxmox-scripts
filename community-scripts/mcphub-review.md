# MCPHub installer review

Reviewed on 2026-11-15 before the initial branch push. This is the implementing agent's manual code review, with executable checks; it is not an independent reviewer approval.

## Scope and evidence

- New native Debian 13 LXC installer, systemd service, versioned npm releases, and update/recovery manager. Existing host utility scripts are unchanged. No Docker deployment remains.
- Published npm package: `@samanhappy/mcphub@1.2.4`, requires Node.js >=22.0.0; package contains `dist/index.js`, `bin/cli.js`, and `frontend/dist/index.html`.
- npm integrity observed: `sha512-4X55j1036x1Ljwzfzbu7Tsvpsyh522jvgdpOz1K5dqXDjgRnwL++Zuwn1aQA3wATJvooNlkFGfm3wSAgYW0ucw==`.
- Upstream 1.2.4 source inspected at `7a47a118014a7401cc2d2e107043a61bc08f2387`, including dependency requirements from its Dockerfile, configuration paths, admin initialization, bearer authentication, and persistent credential key handling.
- Shared engine pinned at `4f6c2bd4dfadce266dca9ec737e8382728d753e3`. Its generated updater was exercised in an isolated directory to verify nested repository and branch URLs and the custom script slug survive.

## Review findings resolved

- Explicitly propagate npm/metadata failures from functions called through command substitution; Bash's errexit alone does not reliably stop those paths.
- Make new release directories traversable by the service user while keeping data/home private and secrets root-readable.
- Restart the previous service after a failed backup or stop attempt; restore both data and runtime home after a failed new-release activation. Keep the original release and failed runtime data for recovery.
- Preserve the private scripts origin and custom slug instead of relying on the official app catalog entry.
- Require the systemd service to be active as well as the HTTP health endpoint to answer before reporting successful activation.
- Correct smoke-test client handling for the dashboard's `x-auth-token` header and MCP session IDs; these were test-harness failures, not installer defects.

No unresolved blocking findings from the manual source review. Runtime validation below is deliberately limited.

## Checks

- `bash -n`: all new shell scripts pass.
- ShellCheck 0.11.0: all new shell scripts pass.
- Eleven offline unit/contract tests pass, covering successful update, same-version handling, invalid input, install failure, stop failure, backup failure, failed startup/health rollback, explicit command-substitution error propagation, the real engine's updater generation, and the service/HTTP readiness gate. Some tests exercise multiple scenarios.
- `systemd-analyze verify`: the generated unit passes parsing/verification in the development environment; local sandbox socket-option warnings were emitted. This does not exercise service startup or the unit's filesystem restrictions.
- Published native npm package smoke: dashboard and `/health` return 200, generated admin login succeeds, settings persist, and unauthenticated MCP is rejected. Authenticated MCP initialization, discovery, and stdio tool forwarding are tested by `tests/smoke_mcphub.py`; all passed against npm 1.2.4.

## Deployment acceptance still required

1. Create a disposable Proxmox LXC with the branch installer and verify all provisioning stages and the hardened systemd service there.
2. Check dashboard rendering in Waterfox and perform an authenticated client tool call using a real configured backend. This change does not modify upstream UI code.
3. Reboot the LXC and verify service/state persistence.
4. Exercise the generated `update` command and an actual service-level upgrade/recovery in the disposable LXC; unit tests currently mock systemctl and HTTP failures.
5. arm64 is declared by the script but has not been provisioned or smoke-tested here.

The scripts have not been run against the user's Proxmox node. No infrastructure credentials or application backends have been configured.
