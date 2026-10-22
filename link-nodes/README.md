# link-nodes.sh: link VerteX appliance nodes

Links the nodes of a VerteX appliance installation through the Local UI API, the same way the
Local UI **Linked Edge Hosts** page does: nodes 2 and 3 join node 1, the leader. It then waits
until node 1 shows every node **Ready**, **Synced** and **Healthy**. Use it after the nodes are
deployed and Local UI answers on each of them, before you create the cluster.

It works however the nodes were deployed, as long as this machine can reach each node's Local
UI.

## Requirements

- macOS or Linux with `bash`, `curl` and `jq`.
- This machine can reach Local UI (port 5080 by default) on every node, directly or through a
  tunnel.
- The nodes can reach each other directly. Linking and syncing run between the nodes.
- Local UI is up on every node. It answers about 25-30 minutes after a node first starts.
- The Local UI user and password, which are the ones in the nodes' user data.

## Usage

```
./link-nodes.sh -u <user> <node1> <node2> [<node3> ...]
```

Give each node as this machine reaches its Local UI: an IP address or host name, with
`:port` if it isn't 5080. Node 1 becomes the leader. The script asks for the password, or
reads it from `LOCALUI_PASSWORD`:

```
./link-nodes.sh -u admin 10.0.11.10 10.0.11.11 10.0.11.12

LOCALUI_PASSWORD='...' ./link-nodes.sh -u admin node1.example.com node2.example.com node3.example.com

./link-nodes.sh -u admin 10.0.11.10:6080 10.0.11.11:6080 10.0.11.12:6080     # Local UI on another port

./link-nodes.sh -u admin [fd00::10] [fd00::11] [fd00::12]                     # IPv6: in brackets
```

Through SSH tunnels, when only one host can reach the nodes:

```
ssh -N -L 15080:10.0.11.10:5080 -L 15081:10.0.11.11:5080 -L 15082:10.0.11.12:5080 user@jump-host &
./link-nodes.sh -u admin localhost:15080 localhost:15081 localhost:15082
```

## What you see

```
[10:02:11] Signing in to Local UI on 3 nodes as admin
  ✓ node 1 (10.0.11.10) signed in: edge host edge-a1b2...
  ✓ node 2 (10.0.11.11) signed in: edge host edge-c3d4...
  ✓ node 3 (10.0.11.12) signed in: edge host edge-e5f6...
[10:02:12] Linking nodes 2-3 to node 1 (10.0.11.10)
  ✓ node 2 (10.0.11.11) linked
  ✓ node 3 (10.0.11.12) linked
[10:02:24] Waiting for node 1 to show every node Ready, Synced and Healthy
  ✓ node 1 (10.0.11.10): Ready, Synced, Healthy
  ✓ node 2 (10.0.11.11): Ready, Synced, Healthy
  ✓ node 3 (10.0.11.12): Ready, Synced, Healthy
  ✓ All 3 nodes are linked: Ready, Synced and Healthy
```

In a terminal, each line updates in place with a spinner until it turns into a check. Then, in
Local UI on node 1, go to **Cluster** > **Create cluster** and add all the nodes in **Node
Config**.

It is safe to run again. Nodes that are already linked are skipped, and the script only waits
for them to be Ready, Synced and Healthy.

## Troubleshooting

| Message | What to check |
| --- | --- |
| Could not sign in ... (HTTP 401) | The user and password. A refused password is not retried, because failed sign-ins count toward Local UI's lockout. |
| Could not sign in ... (HTTP 000) | The address and port, a firewall between this machine and the node, or Local UI not up yet. |
| ... did not accept node 1's link token | Run the script again; it gets a fresh token for each node. A token is valid for two minutes. |
| Linking ... failed: \<message\> | The message comes from the node. Check that the nodes run the same version and can reach each other. |
| ... not in node 1's list yet, or not Synced after 15 minutes | Traffic between the nodes. Then the node's Local UI **Linked Edge Hosts** page. |

Each run writes `link-nodes-<time>.log` in the current folder. It records every Local UI call
and its result. It holds no password and no token, and only you can read it. Include it when
you ask for help.

## Security

- The password is read from `LOCALUI_PASSWORD` or a hidden prompt, never from the command line,
  so it doesn't show in the process list.
- Local UI uses a self-signed certificate, so the script does not verify certificates (`curl
  -k`). Run it from a machine on a network you trust, or through an SSH tunnel.
