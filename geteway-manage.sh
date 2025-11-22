#!/bin/bash

GATEWAY_DIR="/opt/api-gateway"

case "$1" in
    start)
        cd "$GATEWAY_DIR" && docker-compose up -d
        ;;
    stop)
        cd "$GATEWAY_DIR" && docker-compose down
        ;;
    restart)
        cd "$GATEWAY_DIR" && docker-compose restart
        ;;
    status)
        cd "$GATEWAY_DIR" && docker-compose ps
        ;;
    logs)
        cd "$GATEWAY_DIR" && docker-compose logs -f
        ;;
    update)
        cd "$GATEWAY_DIR" && docker-compose pull && docker-compose up -d
        ;;
    info)
        echo "Gateway directory: $GATEWAY_DIR"
        echo "Available commands: start, stop, restart, status, logs, update"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|update|info}"
        exit 1
        ;;
esac