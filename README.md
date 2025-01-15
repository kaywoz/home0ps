# ka's personal homeops documentation etc

![test](https://play.d2lang.com/?script=nJTPi-tGDMfv_iuEYaGF2t44--OtDz2VV3opPfRulBllrHoyY2bkpGHZ_72MnUASmsX7LrGVkaWPRtJXcyAl7F0DgU0nWfYbsj1CUcDfgY2hkF7_cHuKwgaTZ5ZdmVD8Crn24Lx07Ez-P6c90QAHH_o75wOOkT5zkI4OnbcUO9pgcrkOmXwm7Abeoxwtleh4h0K6AQkjfZyqKvXslOfwngGYwLpQ3o47FxtYZRlArjpSPWyJdMxLVuleOpEhNlWltJv-KdJPLJXfVdNbXdXfnqu__vy9enupoleMtg0xthv_b-sDOkNt_fzSrh9f1utycCalSeSwQdVbb27zzOGFQsAoYVQypRJS3UP93eIgfijjfgoTyZIS2PoAmvZfAH6q3ybi51Vd_cMBW-uNb9Npu3p6rV-fzqB7tKxRCDQKLiOlGMkJo40P9ffHb29F-vShfkSH9hg5nuE1DdYfQTyoMYrfUYg_kGD1uiq2Fs0p6tT-ZmovgB9QsRxTb5O5ZWsbOHQsNNnr03hMRpTge2pgY1H1GcBH9pFlpxUoZX5-OjndcfDSUeSYJ5O9Oj0xX8Q1sOsXYl0tSMmX1qeIEhgNzVhOsSYnECgO3kVaBmmTRhzJWn9YyHopDc2VUNzHxNiD8rvBkpD-ApgJRG4p15WCNDcidb_LoxNAg-ymawykxhDYGdAks5CCI9JLsWd9WIp8rZPNWTjRaTggzzpw3qX7JQQafJDLvTuVkgZBT9EoKrRp62-cFvZhY8fFNd1K-zwjLIDW3q8BrQW_BekIcOP3C6c3t-wIQ2ECaiYnPwXSv1yMzs_5Mur_AgAA__8%3D&sketch=0&layout=elk&theme=1&)


![Static Badge](https://img.shields.io/badge/Free_&_Open_source-GPL_V3-green)

This project will document a self-hosted environment running on an **Odroid M1** board and is supposed to be self contained.

It is meant to maximise the homeops (lul) enviroment and just run on this single board, with as many apps and services as possible.

The project will only use **free** and/or **open source** software, the enterprise stuff will run in the homelab-environment.


> [!IMPORTANT]
> The content of this repository is provided "as is", with no guarantee that the information is complete or error-free.
> The techniques and tools discussed here come with inherent risks.
> The author takes absolutely no responsibility for possible consequences due to the use of the related software.

# Table of Content
 

1. <details>
   <summary><a href="#overview">Overview</a></summary>

    1. [Plan](#plan)
    2. [Architecture](#architecture)

   </details>
2. <details>
   <summary><a href="oOdroid setup">Odroid setup</a></summary>

    1. [step-name](#step-comment)

   </details>
3. <details>
   <summary><a href="#initial-prep">Initial prep</a></summary>

    1. [step1](#step1)


   </details>
4. <details>
   <summary><a href="#network-configuration">Network configuration</a></summary>

    1. [ip-stuff](#ip-stuff)

   </details>
5. <details>
   <summary><a href="#install-services">Install services</a></summary>

    1. [service1](#service1)
   
   </details>

6. <details>
   <summary><a href="#docker-apps">Docker apps</a></summary>

    1. [app1](#app1)

   </details>


7. <details>
   <summary><a href="#acknowledgments">Acknowledgments</a></summary>
   </details>

8. <details>
   <summary><a href="#license">License</a></summary>
   </details>
  
# Overview

## Plan

There have been many steps in this project, and it has been hosted on different hardware, running different stacks of software since 2022?

The primary design principles were set to the following, after much deliberation;

- **kiss** (because I always overcomplicate everything)
- **self-hosted within reason** (take the hardware as far as it goes, reach out to cloud when there is a determined need)
- **privacy first** (software should honor privacy, encrypt everything))
- **cloud-agnostic** (cheapest and best is the way to go)
- **secure** (authentication, zero-trust, encryption, logging, backup etc)
- **light** (4 arm-cores and 4GB RAM is not a lot.)
- **container-first** (for deployability, transferability etc.)
- **accessible** (usability wherever I'm at)
- **monitored** (monitoring, alerting, tracking, the good stuff)

These are the tools we are going to run :

|                                       Logo                                        | Name           | Repository                                  | Description                                          |
|:---------------------------------------------------------------------------------:|----------------|---------------------------------------------|------------------------------------------------------|
|         <img src="images/logo-docker.svg" alt="Docker logo" height="24"/>         | Docker         | https://github.com/docker                   | Help to build, share, and run container applications |
| <img src="images/logo-docker-compose.png" alt="Docker Compose logo" height="38"/> | Docker Compose | https://github.com/docker/compose           | Run multi-container applications with Docker         |
|          <img src="images/logo-kopia.png" alt="Kopia logo" height="32"/>          | Kopia          | https://github.com/kopia/kopia              | Fast and secure open-source backup/restore tool      |
|    <img src="images/logo-uptime-kuma.svg" alt="Uptime Kuma logo" height="34"/>    | Uptime Kuma    | https://github.com/louislam/uptime-kuma     | Easy-to-use self-hosted monitoring tool              |
|    <img src="images/logo-tailscale.png" alt="Tailscale logo" height="34"/>    | Tailscale    | https://github.com/tailscale/tailscale    | Private WireGuard® networks made easy|

Below is a general connectivity diagram for the hosted services;

```mermaid
flowchart TB

    style tailnet fill: #69582b
    style provider-tailscale fill: #69587b
    style provider-cloudflare fill: #205566
    style docker fill: #664343
    style container fill: #612
    style firewall fill: #615
    style client fill: #4d683b
    style reverse-proxy fill: #806930

    SUBDOMAIN_MYAPP1(public-app.krypi.net) --> | cf-tunnel| firewall --> |bypass| container
    SUBDOMAIN_MYAPP2(internal-app.krypi.net) --> | tailscale sidecar| firewall --> |bypass| container

   subgraph client[client connects via]
        provider-cloudflare[cloudflare] --> |zta| ddns
        provider-tailscale[tailscale] --> |vpn  and acl| tailnet
    end

subgraph ddns[cloudflare]
        reverse-proxy -->|subdomain| SUBDOMAIN_MYAPP1
    end

subgraph tailnet[tailnet]
        tailnet --> SUBDOMAIN_MYAPP2
    end


    subgraph sbc[odroid m1]
        subgraph docker[docker]
            subgraph container[containers]
                    tailscale[tailscale]
                    cloudflare[cloudflare]
                    public-app[public-app]
                    internal-app[internal-app]
            end

        end

    end

```


# Acknowledgments

Acks go here :

# License

Please refer to the license of each product mentioned in this guide.

Otherwise, the **GPL v3** license applies.

[General Public License (GPL) v3](https://www.gnu.org/licenses/gpl-3.0.en.html)

This program is free software: you can redistribute it and/or modify it under the terms of the GNU
General Public License as published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without
even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not,
see <http://www.gnu.org/licenses/>.