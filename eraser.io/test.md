## overall h0me0ps status ![global homeops status](https://healthchecks.io/badge/10bf082e-0d94-4d53-a830-0adc6d8b87dd/F8fDUjAa/homeops.svg)
# h0me0ps jobs n' scripts
![123](https://healthchecks.io/badge/10bf082e-0d94-4d53-a830-0adc6d8b87dd/skb2Y2vI-2/archive.svg)
![backups](https://healthchecks.io/badge/10bf082e-0d94-4d53-a830-0adc6d8b87dd/uO9OO8ww/backups.svg)
![certs](https://healthchecks.io/badge/10bf082e-0d94-4d53-a830-0adc6d8b87dd/DZHBpt3r/certs.svg)
![dns](https://healthchecks.io/badge/10bf082e-0d94-4d53-a830-0adc6d8b87dd/xtdIJeoK/dns.svg)
![wrk](https://healthchecks.io/badge/10bf082e-0d94-4d53-a830-0adc6d8b87dd/R9m9MlEA/wrk.svg)
![Static Badge](https://img.shields.io/badge/name%20of%20stuff-you_like-blue)
![123](https://img.shields.io/github/commit-activity/w/kaywoz/Bluestuff)
![123](https://shields-ops.krypi.net/endpoint?url=https://gatus.krypi.net/api/v1/endpoints/baremetal_docker---plenty-penguin---ping/health/badge.shields&label=baremetal%20plenty-penguin)



![grunty02.cloud.krypi.net - f@h reported credits](https://healthchecks.io/b/3/b786d7da-f2a6-433e-81e1-dec11502d235.svg)

![GitHub commit activity](https://img.shields.io/github/commit-activity/m/kaywoz/bluestuff?label=repo%3Abluestuff%20commits)

![GitHub commit activity](https://img.shields.io/github/commit-activity/m/kaywoz/gluestuff?label=repo%3Agluestuff%20commits)

![GitHub commit activity](https://img.shields.io/github/commit-activity/m/kaywoz/kaywoz.github.io?label=repo%3Akaywozplayz%20commits)

![GitHub commit activity](https://img.shields.io/github/commit-activity/m/kaywoz/home0ps?label=repo%3Ahome0ps%20commits)

![GitHub commit activity](https://img.shields.io/github/commit-activity/m/kaywoz/ctfstuff?label=repo%3Actfstuff%20commits)

[![Terraform-cloudflare](https://github.com/kaywoz/terraform-cloudflare/actions/workflows/terraform.yml/badge.svg)](https://github.com/kaywoz/terraform-cloudflare/actions/workflows/terraform.yml)

---
title: review (pt1)- unsatisfactory hardware, gah
date: 2024-04-019 13:01:00 +0100
categories: [homelab]
tags: [homelab,troubleshooting,hardware]     # TAG names should always be lowercase
comments: true
---

# Intro

Aight, so I finally found somewhat of a solution to a problem I've had for some time. The ever elusive "how to solve the server in the closet connectivity and access if all breaks"-problem. Now, granted, I've not really had that much of a problem like this since more or less all of the service i build in homeops are for myself, not even the gf consumes them. My problem is easier than that, if I break something (something which happens more often than I'd like to admin) I get reeaaaalllly frustrated pulling hdmi-cables from tv-sets to have display for the server and dig out the usb octopus cable connectors for keyboard, usb memory stick, mouse in that order. Cant do it anymore, just so much frustration to deal with. 

So, I've been looking towards the [piKVM](https://pikvm.org/buy/) product and it's similar siblings, but it's simply to expensive, and yes I like tinkering. But no I dont want to tinker with this and buy hats and accessories and install software etc. I just want it to work, that is ok sometimes too!

So I found the [Aurga Viewer](https://www.aurga.com/), an hdmi hotspot device for cheap(er)...

# The product

Well, to start with it's small, ![aurga viewer](/assets/images/2024-04-19-unsatisfactory-hardware-review-pt1/1.jpg) but that's to be expected as it only needs the hdmi-port and usb for power.

Barely any accessories, ![accessories](/assets/images/2024-04-19-unsatisfactory-hardware-review-pt1/2.jpg) 

And, yes, really small; ![size](/assets/images/2024-04-19-unsatisfactory-hardware-review-pt1/3.jpg)


I tried the regular things, checking the tailnet access permissions (since Im am going to have a fairly restrictive model) 
![aurga viewer](/assets/images/2024-04-19-unsatisfactory-hardware-review-pt1/1.jpg)
 the tailscale interface firewall rules,
![firewall tailscale interface access](/assets/images/2024-04-02-trouble-in-paradise-pt4/2.png)
 that the tailscale interface is an allowed listener....
 ![tailscale interface set as listener](/assets/images/2024-04-02-trouble-in-paradise-pt4/3.png)

But to no avail. It still wasn't working. Some googling and dorking about later and i found this thread on [Reddit](https://www.reddit.com/r/OPNsenseFirewall/comments/11ww0sx/how_to_access_gui_via_tailscale_ip_address_on/)

According to the post, asymmetric routing is the culprit. M'ok, sounds plausible and it works for me by changing the CIDR to /10 and keeping the above as they are indeed necessary.

One might need to disable DNS rebinding checks/HTTP_REFERER checks as I've done in the pix or do some other magic if you like me, are NOT running split DNS. I run all(?) dns in cloudflare, even local homelab dns records. 

# Closing thoughts

All is good in tailscale land and I can keep the opnsense GUI off regular lan, most vlan etc. Feels nice doesn't it. Just need more time to start rolling out the main tailscale node filtering and I'm gonna be happy.











