/*
 * CAbyssProtocols — the interface tables of the Wayland protocols this project
 * defines itself (PHASE10.md P10.3), compiled exactly once.
 *
 * `wayland-scanner private-code` emits the same `wl_interface` definitions for
 * a client and for a server. Generated into CWayland *and* CWlroots, they would
 * be two definitions of one symbol in every binary that links both — and
 * `swift test` links every test target into one. So the tables live here, the
 * client header lives in CWayland and the server header in CWlroots, and both
 * depend on this target. Nothing to declare: the headers declare the tables.
 */
#ifndef ABYSS_CABYSSPROTOCOLS_H
#define ABYSS_CABYSSPROTOCOLS_H
#endif
