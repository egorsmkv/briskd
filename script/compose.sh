# Shared by the host-side test and bench scripts. Source it, then call
# `compose` with the same arguments as Docker Compose.
#
# Prefers Compose v2 (`docker compose`). Falls back to Compose v1
# (`docker-compose`), which is what this repository's development host has.
compose() {
    if [ -z "${_COMPOSE_KIND:-}" ]; then
        if docker compose version >/dev/null 2>&1; then
            _COMPOSE_KIND=v2
        elif command -v docker-compose >/dev/null 2>&1; then
            _COMPOSE_KIND=v1
        else
            echo "compose: install Docker Compose (docker compose or docker-compose)" >&2
            return 127
        fi
    fi
    if [ "$_COMPOSE_KIND" = v2 ]; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}
