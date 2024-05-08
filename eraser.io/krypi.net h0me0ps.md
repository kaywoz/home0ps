title krypi.net h0me0ps

// Physical layer contains actual hardware and their operating systems
hardware [color: darkblue] {
  Sexy-serval [icon: server] // xcp-ng
  Edgy-elephant [icon:server] // xcp-ng
  Nasty-nightfish [icon: storage] // casaos, acts as NAS
  Plenty-penguin [icon: storage] // ubuntu
  Wally-wombat [icon: firewall] // Firewall
}

// Logical layer represents the separation of networks based on VLANs
network [color: green] {
  VLAN1-Trust-Untagged [icon: network-wired]
  VLAN2-Trust-Hypervisor [icon: network-wired]
  VLAN3-Trust-Storage [icon: network-wired]
  VLAN4-Trust-Docker [icon: network-wired]
  VLAN13-Untrust-IoT [icon: network-wired]
  VLAN42-Trust-Mgmt [icon: network-wired]
  VLAN99-Untrust-DMZ [icon: network-wired]
  VLAN100-Untrust-Lab [icon: network-wired]
  VLAN666-Danger-Void [icon: network-wired]
}

// Virtual layer includes VMs and containers running on the physical servers
services [color: lightcoral] {
  VMs-on-XCP-NG [icon: vm]
  Containers-on-docker [icon: docker]
}

// Overlay layer connects all nodes with specific service filters
tailscale [color: orange] {
  Snow-Koi.ts.net [icon: tailscale] // Tailscale tailnet
}

// Connections within Physical layer
// Sexy-serval and Edgy-elephant run xcp-ng
Sexy-serval > VLAN2-Trust-Hypervisor
Edgy-elephant > VLAN2-Trust-Hypervisor
// Nasty-nightfish runs casaos and acts as NAS
Nasty-nightfish > VLAN3-Trust-Storage
// Plenty-penguin runs ubuntu
Plenty-penguin > VLAN4-Trust-Docker

// Connections within Virtual layer
// VMs run on xcp-ng hosts
VMs-on-XCP-NG > VLAN42-Trust-Mgmt
VMs-on-XCP-NG > VLAN99-Untrust-DMZ
VMs-on-XCP-NG > VLAN100-Untrust-Lab
VMs-on-XCP-NG > VLAN666-Danger-Void
// Containers run on docker on Plenty-penguin
Containers-on-docker > VLAN42-Trust-Mgmt
Containers-on-docker > VLAN99-Untrust-DMZ

// Connections within Overlay layer
// Overlay connects all nodes but with a filter for each service
Snow-Koi.ts.net > hardware
Snow-Koi.ts.net > services

// Wally-wombat connections
// Firewall connected to overlay and all logical layers
Wally-wombat > Snow-Koi.ts.net
Wally-wombat > VLAN1-Trust-Untagged
Wally-wombat > VLAN2-Trust-Hypervisor
Wally-wombat > VLAN3-Trust-Storage
Wally-wombat > VLAN4-Trust-Docker
Wally-wombat > VLAN13-Untrust-IoT
Wally-wombat > VLAN42-Trust-Mgmt
Wally-wombat > VLAN99-Untrust-DMZ
Wally-wombat > VLAN100-Untrust-Lab
Wally-wombat > VLAN666-Danger-Void