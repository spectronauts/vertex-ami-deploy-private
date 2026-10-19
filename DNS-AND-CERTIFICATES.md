# DNS and certificates for VerteX

VerteX installs with its VIP as its address and a self-signed certificate. That works, with a
browser warning, as long as users reach it by IP address. To give it a name users trust you
need DNS records for that name and a TLS certificate for it. This page lists what is required,
where each piece goes, and when, based on the Spectro Cloud documentation (sources at the end).

The examples use `vertex.example.com` as the name and `10.0.11.210` as the VIP
(`NLB_PRIVATE_IP` in `config.env`).

## What you need

| Item | Required | Where it goes | When |
| --- | --- | --- | --- |
| DNS record: `vertex.example.com` → VIP | To use a name instead of the IP | A Route 53 private hosted zone for the VPC, and your network's DNS for users | Before VerteX is given the name |
| DNS record: `*.vertex.example.com` → VIP | Once a tenant uses single sign-on (users then sign in at `<tenant>.vertex.example.com`); recommended from the start | Same | Same |
| TLS certificate, key and CA chain for the name | To replace the self-signed certificate | System console: **Administration** > **System Address** (or `./configure.sh`) | Any time after install |
| Local UI certificate (port 5080) | No action | | |
| Internal registry certificate (VIP port 30003) | No action; VerteX manages it | | |

## 1. Choose the name

Pick one fully qualified domain name (FQDN) for VerteX, such as `vertex.example.com`. Tenants
get a subdomain of it: a tenant named `tenant1` is at `tenant1.vertex.example.com`.

With one tenant, local accounts and single sign-on (SSO) off, users can reach VerteX at its IP
address or any name that resolves to it. Once SSO is on, users must sign in at the tenant's
subdomain, which is why the wildcard record is recommended.

You can give VerteX the name at either of two points:

- **At install (simplest):** in Local UI, **Profile Config** > **Management Plane** > **Root
  Domain**. The default is the VIP; enter the FQDN instead. Create the DNS records (Step 2)
  before you click **Deploy Cluster**.
- **After install:** in the system console, **Administration** > **System Address**, together
  with the certificate (Step 3). Clusters that VerteX deployed before the change may need their
  address updated (Step 4).

## 2. Add the DNS records

**The name must resolve inside the VPC.** VerteX checks that the system address is reachable
from the system console, and the nodes and the clusters VerteX manages reach it by that name.
In this private-only VPC, that means a Route 53 private hosted zone associated with the VPC.
Private hosted zones need the VPC's DNS support and DNS hostnames turned on, which
`./create-aws-infra.sh` does.

| Name | Type | Value |
| --- | --- | --- |
| `vertex.example.com` | A | `10.0.11.210` (the VIP) |
| `*.vertex.example.com` | A | `10.0.11.210` |

Point both at the VIP: it is the NLB's fixed private IP, and the NLB forwards ports 443, 6443,
30003 and 5080 to the nodes.

With the AWS CLI (replace the VPC ID; the zone ID comes from the first command's output):

```
aws route53 create-hosted-zone --name vertex.example.com --caller-reference vertex-$(date +%s) \
  --vpc VPCRegion=us-gov-west-1,VPCId=<vpc-id> --hosted-zone-config PrivateZone=true

cat > records.json <<'EOF'
{"Changes": [
  {"Action": "UPSERT", "ResourceRecordSet": {"Name": "vertex.example.com", "Type": "A", "TTL": 300,
    "ResourceRecords": [{"Value": "10.0.11.210"}]}},
  {"Action": "UPSERT", "ResourceRecordSet": {"Name": "*.vertex.example.com", "Type": "A", "TTL": 300,
    "ResourceRecords": [{"Value": "10.0.11.210"}]}}
]}
EOF
aws route53 change-resource-record-sets --hosted-zone-id <zone-id> --change-batch file://records.json
```

Check it from a node (`./connect.sh ssh 1`):

```
getent hosts vertex.example.com tenant1.vertex.example.com     # both print 10.0.11.210
```

**Users' workstations** don't see a private hosted zone. Either:

- your DNS team adds the same two records to the DNS your users use (or forwards
  `vertex.example.com` to a Route 53 Resolver inbound endpoint in the VPC), or
- through `./connect.sh console` (which forwards the VIP's 443 to local port 8443), add the names
  to `/etc/hosts` on the workstation and use port 8443. Hosts files take no wildcards, so list
  each tenant:

  ```
  127.0.0.1  vertex.example.com tenant1.vertex.example.com
  ```

  Then open `https://vertex.example.com:8443/system`.

## 3. Add the certificate

**Requirements:**

- An x509 certificate and its private key in PEM format. The certificate file must contain the
  full chain. Ask your security team or certificate authority for these.
- The certificate authority (CA) chain that issued it, also PEM.
- Subject Alternative Names (SANs) that cover:
  - `vertex.example.com`
  - `*.vertex.example.com`, if tenants will use their subdomains (SSO)
  - **the previous address**: the new certificate must also include the DNS name or IP address
    VerteX used before, so existing connections are not interrupted. After an install with the
    default Root Domain, that is the VIP as an IP SAN (`10.0.11.210`).
- Not expired, and valid for the CA and the system address. VerteX checks the combination of
  address, certificate, key and CA, and refuses a set that doesn't match.

For example, a certificate request with:

```
subjectAltName = DNS:vertex.example.com, DNS:*.vertex.example.com, IP:10.0.11.210
```

**Where to add it:**

- **System console:** **Administration** > **System Address**. Enter the FQDN in **System
  Address (UI and API)**. The **Certificate**, **Key** and **Certificate Authority** fields
  take base64-encoded files:

  ```
  base64 < certificate.crt | tr -d '\n'
  ```

  Repeat for the key and the CA file, paste each into its field, and click **Update**.
- **Or `./configure.sh`:** in `system.env`, set `DOMAIN_HOST` to the FQDN and `TLS_CERT_FILE`,
  `TLS_KEY_FILE` and `TLS_CA_CERT_FILE` to the PEM files. It base64-encodes them, checks that
  the certificate hasn't expired and names `DOMAIN_HOST`, and uploads them.

VerteX then refreshes its listening ports and uses the new certificate. Sign out of the system
console and close the browser (browsers keep the old connection), then open
`https://vertex.example.com/system`.

To see the certificate VerteX now serves, from a node:

```
openssl s_client -connect 10.0.11.210:443 -servername vertex.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -enddate -text | grep -E 'Subject:|Not After|DNS:'
```

You can replace the certificate again at any time (before it expires, for example) without
affecting VerteX.

## 4. Changing the address later

Changing the system address after clusters have been deployed can disconnect them:

- Keep both the old and the new name (or IP) resolving and in the certificate until every
  cluster uses the new address.
- A cluster that shows **Unknown** after the change needs its address updated by hand: with
  that cluster's kubeconfig, set `apiEndpoint` in the `hubble-info` ConfigMap in its
  `cluster-<id>` namespace to the new address (`kubectl edit configmap hubble-info -n
  cluster-<id>`).

Setting the name at install (Step 1) avoids this.

## Certificates that need no action

- **Local UI (port 5080 on each node):** uses a self-signed certificate. The browser warning is
  expected and safe to accept.
- **The internal Zot registry (VIP port 30003):** VerteX creates and distributes its
  certificate. From VerteX 4.10.25, it can rotate it automatically: after upgrading, turn on
  **Enable Certificate Rotation** in Local UI (**Cluster** > **Configuration** > **Applications
  Config** > **Container Registry**). Without rotation, the registry certificate eventually
  expires unless rotated by hand, and clusters then can't pull images from it. Follow the
  upgrade guide's steps, which include a one-time script on 4.10.25.
- **An external registry** (only if you set **In Cluster Registry** to `False`): give its CA
  certificate, base64-encoded, in **OCI Pack Registry Ca Cert** under **Profile Config** >
  **Container Registry**.

## Optional: reverse proxy (Spectro Proxy)

If you add Spectro Proxy so users can reach the APIs of clusters that VerteX manages, it needs
its own domain name (a CNAME record for its load balancer) and a certificate that matches that
name. See the reverse proxy guide below.

## Sources

Spectro Cloud documentation:

- [System Address Management](https://docs.spectrocloud.com/vertex/system-management/ssl-certificate-management/):
  system address, certificate requirements, upload, and reconciling clusters
- [VerteX Management Appliance](https://docs.spectrocloud.com/vertex/install-palette-vertex/vertex-management-appliance/):
  Root Domain, registry and certificate options at install; self-signed certificates
- [Install VerteX on VMware](https://docs.spectrocloud.com/vertex/install-palette-vertex/install-on-vmware/install/):
  tenant subdomains and the wildcard DNS record
- [Tenant Management](https://docs.spectrocloud.com/vertex/system-management/tenant-management/)
- [Upgrade the VerteX Management Appliance](https://docs.spectrocloud.com/vertex/upgrade/vertex-management-appliance/):
  registry certificate rotation
- [Reverse Proxy](https://docs.spectrocloud.com/vertex/system-management/reverse-proxy/)

AWS documentation:

- [Working with private hosted zones](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zones-private.html)
- [Route 53 Resolver](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resolver.html):
  inbound endpoints for resolving the private zone from your network
