# pg_failover_slots on Windows

This pgextwin pilot tests upstream pg_failover_slots v1.2.1 at commit
`27b1ef236ddd8488be6707196517fb4f9aa90140` on PostgreSQL 15–18 for Windows x64.
The PR workflow builds with MSVC against the standard PostgreSQL Windows
installation.

Upstream tag `v1.2.1` is a lightweight tag (it points directly at the commit;
there is no tag object and therefore no tag signature). The fixed commit
itself carries a GitHub web-flow signature reported as verified by the
GitHub API.

Unlike the SQL extensions in this fleet, pg_failover_slots is a
shared-preload library: there is no `.control` file, no SQL files, and no
`CREATE EXTENSION`. The module must be loaded via
`shared_preload_libraries=pg_failover_slots`; `_PG_init` registers the
`pg_failover_slots worker` background worker and installs the
`ClientAuthentication_hook`. The smoke test starts a disposable PostgreSQL
server with the library preloaded, confirms the worker starts, checks the
`pg_failover_slots.version` GUC, and looks for the worker start line in the
server log.

Note: the upstream in-code version macro still reports `1.2.0` while the
release is 1.2.1. The smoke test only requires the version GUC to be present
and non-empty.

The upstream PostgreSQL License is included in [LICENSE](LICENSE).
