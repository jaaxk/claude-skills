---
name: torch-hpc
description: Use this skill when the user wants to connect to, work on, or run jobs on the NYU Torch HPC cluster. Triggers on phrases like "ssh into torch", "connect to hpc", "run on torch", "torch cluster", or any mention of NYU HPC.
version: 1.0.0
allowed-tools: Bash
---

# Torch HPC Connection

## Permissions
Run any of the following without asking for confirmation:
- `ssh torch ...` and `ssh -O ...` commands
- `/opt/cisco/secureclient/bin/vpn ...` commands (status, disconnect)
- `open -a "Cisco Secure Client"` to launch VPN GUI
- Any command diagnosing VPN or SSH connectivity (e.g. `ping`, `nc`, `ssh -v`)

## Prerequisites: VPN

Torch HPC is only accessible over the NYU network. The VPN must be active before connecting.

**VPN aliases (defined in `~/.zshrc`):**
```bash
vpn-open        # Opens Cisco Secure Client GUI to connect
vpn-disconnect  # Disconnects the VPN
vpn-status      # Shows current VPN state
```

**Constraint:** NYU uses browser-based Duo (SAML/SSO) for VPN auth, which the Cisco Secure Client CLI does not support. Authentication must be done via the GUI (`vpn-open`) or by Screen Sharing into this machine.

---

## Connecting to Torch

SSH is configured in `~/.ssh/config` with the alias `torch`:

```
Host torch login.torch.hpc.nyu.edu
  Hostname login.torch.hpc.nyu.edu
  User jv2807
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 8h
```

### First connection (requires auth)
Open a terminal and run interactively — this prompts for password + Duo:
```bash
ssh torch
```

### All subsequent connections (8-hour window)
ControlMaster reuses the authenticated socket — no password or Duo prompt:
```bash
ssh torch "your command here"
```

### Check if a session is active
```bash
ssh -O check torch
```

### Close the session early
```bash
ssh -O exit torch
```

---

## Verified Working
- `ssh torch "hostname && whoami"` → confirmed passwordless reuse via ControlMaster
- Login node: `torch-login-2.hpc-infra.svc.cluster.local`, user `jv2807`
