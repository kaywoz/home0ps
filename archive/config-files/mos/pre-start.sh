#!/bin/bash
# home0ps: userns-remap config before Docker starts (kaywoz/home0ps#310).
# Host path: /boot/optional/scripts/pre-start.sh, 600. mos-start copies it to /tmp and runs it
# before Docker, LXC and cron start. Must never fail the boot, hence `|| true`.
bash /boot/config/home0ps/docker-userns.sh || true
