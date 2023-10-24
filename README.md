# dockerlab
Configuration for Docker Services running on homelab infrastructure.
The repo is broken down into a series of stacks (docker-compose files) segmented by theme/service- some services may require an application + database container, while other services may depend on a different service (i.e. Tautulli & Plex).


This repo is designed to be modular. First, deploy the `central-host` stack to spin up a portainer & traefik instance, which provides a reverse proxy to services & container management. Then, additional stacks can be deployed through portainer & git, which allows stacks to automatically update when a change is detected. 

## Current Stacks
- mealie
- media (plex & tautulli)
- rtl-amr
- uptime (kuma)
- vaultwarden
