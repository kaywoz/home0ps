# Switch port plan (DRAFT — not decided)

Proposal for the core switch (16 ports: 12× 1 GbE, 4× 2.5 GbE, 2× SFP+) and
a 5-port 2.5 GbE lab switch. Parked by kaywoz on 2026-10-31 to think it over;
nothing is cabled to this plan yet. Background: kaywoz/home0ps#174.

## Principles

- A link runs at the speed of its slower end. The gateway's LAN port is
  2.5 GbE; on a 1 GbE switch port it negotiates 1G, which caps all routed
  (inter-VLAN) traffic at 1G.
- The four 2.5 GbE ports go to the links that gain from 2.5G: the gateway
  uplink, the storage host, the lab switch uplink and the admin workstation;
  the monitoring host gets 2.5G on an SFP+ port.
- Guests on the storage host get one whole NIC port each (PCI passthrough or
  LXC `phys`), on an access port of their VLAN. No trunk to the storage host.
- Lab traffic stays on the lab switch: hypervisors and the lab management VM
  switch at 2.5G locally and never cross the core switch or the gateway.

## Core switch

| Port | Speed | Use | VLAN | Notes |
|---|---|---|---|---|
| 1 | 1G | spare | — | was the gateway uplink |
| 2 | 1G | apps VM (storage-host NIC) | 31 | access |
| 3 | 1G | access point | uplink | unchanged |
| 4 | 1G | game console | 13 | unchanged |
| 5 | 1G | monitoring host (until it moves to SFP+ 17) | 61 | then spare |
| 6 | 1G | infra VM (storage-host NIC) | 24 | access |
| 7 | 1G | spare | — | |
| 8 | 1G | media LXC (storage-host NIC) | 13 | access |
| 9–11 | 1G | KVM-over-IP devices | 23 | unchanged |
| 12 | 1G | lighting bridge | 13 | unchanged |
| 13 | 2.5G | storage host | 22 | after the old storage host is removed |
| 14 | 2.5G | lab switch uplink | trunk 21, 71, 72 | lab only |
| 15 | 2.5G | gateway uplink | uplink | |
| 16 | 2.5G | admin workstation dock | 11 | unchanged |
| 17 | SFP+ | monitoring host, 2.5G USB NIC | 61 | needs an RJ45 module that links at 2.5G (#175); it can push 2.5G in some loads (backups, #178) |
| 18 | SFP+ | spare | — | |

## Lab switch (5× 2.5 GbE)

| Port | Use | VLAN |
|---|---|---|
| 1 | uplink to core port 14, PoE-powered from it | trunk 21, 71, 72 |
| 2–3 | lab hypervisors | native 21, tagged 71, 72 |
| 4–5 | spare (lab) | — |

## Open before deciding

- [ ] Measure routed throughput (iperf3, workstation VLAN 11 → storage host
      VLAN 22) before and after moving the uplink — the gateway may not route
      at 2.5G, especially with IDS/IPS on (#190)
- [ ] SFP+ 17 for the monitoring host: a multi-gig RJ45 module that links at
      2.5G (today's modules show anomalies and one linked at 1G, #175)
- [ ] Port profiles: replace the stale `hypervisor` / `oob` profiles on ports
      that change use

## Order (once decided)

1. Gateway uplink port 1 → 15 (copy port 1's settings first; brief outage,
   do it on site).
2. Remove the old storage host; storage host from SFP+ → port 13.
3. Cable storage-host guests to ports 6 (infra), 2 (apps), 8 (media); set
   each port's VLAN profile.
4. Lab switch on port 14 (PoE-powered), hypervisors on the lab switch.
5. Monitoring host: 2.5G USB NIC on SFP+ 17 once #175 is fixed.
