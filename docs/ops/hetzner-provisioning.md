# Hetzner provisioning

No infrastructure is created by this document. Creating a server starts billable usage and requires an explicit operator decision.

## Required inputs

- Production and staging server names
- Hetzner location inside the EEA
- Current supported Linux LTS image
- Server type sized for measured load
- Named SSH administrators and their public keys
- Fixed office/VPN source ranges for SSH where practical
- Off-host backup destination in a separate failure domain
- Monitoring and alert destination
- Monthly cost ceiling

## Project boundary

Use the dedicated Hetzner Cloud project and local `hcloud` context named `lawrelay`. Confirm the active context before every command:

```sh
hcloud context active
hcloud server list
```

Never reuse credentials or networks from another product.

## Provisioning checklist

1. Add named SSH public keys. Do not share a private key.
2. Create a cloud firewall:
   - SSH only from approved administrator/VPN ranges.
   - TCP 80 and 443 from the internet for Kamal Proxy.
   - No public database, Docker daemon, metrics, or application port.
3. Create one staging server first.
4. Create the production server only after the staging deploy, backup, restore, and rollback exercises pass.
5. Disable password authentication and direct root login after the deploy account works.
6. Create a `deploy` user with narrowly scoped sudo access.
7. Install Docker from its supported repository and enable automatic security updates.
8. Configure host time synchronization and the Europe/Brussels application timezone.
9. Enable the provider firewall and a host firewall; document both rule sets.
10. Send host and Docker logs to the selected retention/monitoring system.
11. Configure disk, memory, CPU, certificate, container-health, queue, and backup alerts.
12. Record the server ID, public IPs, image, region, owner, creation date, and deletion procedure.

## DNS and TLS

- Point `lawrelay.be` to the production IP only after staging acceptance.
- Create `www.lawrelay.be` and redirect it to the canonical host.
- Use Kamal Proxy for Let's Encrypt certificates.
- Do not enable an AAAA record until IPv6 is configured and tested end to end.
- Verify certificate renewal alerts before launch.

## Hardening verification

From an external network, confirm that only intended ports are reachable. Then verify:

- SSH password and root logins are rejected.
- The deploy user can deploy but cannot read unrelated secrets.
- Docker does not listen on a public socket.
- Reboot restores Docker, firewall, monitoring, and the application.
- Security updates do not silently reboot during a court-critical usage window.
- A lost administrator key can be revoked without rebuilding the server.

## Cost controls

Set provider budget alerts where available and a monthly manual cost review. Do not enable volumes, load balancers, snapshots, object storage, or additional servers without an owner, purpose, retention/deletion rule, and expected monthly cost.
