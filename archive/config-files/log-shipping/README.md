# Log shipping (archived 2026-11-19)

Fluent Bit (native, sandboxed) reading the journal and shipping to LogTide, archived with LogTide (benched since 2026-11-02, kaywoz/home0ps#207). Not deployed or maintained.

The journald and Docker log-driver parts still in use moved to [`config-files/logging/`](../../../config-files/logging/). `setup-log-shipping.sh` here is the original combined script and expects `daemon.json` and `journald-50-logging.conf` next to it.

To revive: restore LogTide (`archive/docker-compose/logtide/`), its Services and grants, issue a **new** ingest key, then install Fluent Bit with these files.
