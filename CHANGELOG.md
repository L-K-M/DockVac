# Changelog

## Unreleased

- Scan the local Docker daemon over its unix socket and show images, containers, volumes,
  and build cache as a treemap with exact sizes, including a tile for layers shared
  between images.
- Explain each item: in use or reclaimable, which containers depend on it, whether an
  image can be pulled again, and how much removing it frees.
- Collect items into a cleanup list, review the exact ordered operations and their
  `docker` equivalents, confirm explicitly, and remove them one by one without `force`,
  with per-item outcomes, Stop, and an automatic rescan.
- Discover the daemon through `DOCKER_HOST`, the active Docker context, and the socket
  paths used by Docker Desktop, OrbStack, Colima, Rancher Desktop, and Lima.
- Add the app icon, generated from `media-sources/icon.png`.
- Scaffold the native macOS app and Foundation-only core.
- Add local build, install, and release tooling.
- Add CI, draft release publishing, dependency updates, and GLM PR review.
