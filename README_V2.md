# dockerlab
Configuration for Docker Services running on homelab infrastructure.
The repo is broken down into a series of stacks (docker-compose files) segmented by applicaton and application groups - some services may require an application + database container, while other services may depend on a different service (i.e. Tautulli & Plex).

This updated (in progress) implementation is now less modular than the previous iteration but 
has much more of its configuration maintained within the codebase, instead of being spread across several UIs. 

Pangolin sits at the center of this layout: it fronts every containerized service meant for the web, combining Traefik as the reverse proxy with a WireGuard tunnel so those endpoints stay reachable no matter which machine actually runs them.



