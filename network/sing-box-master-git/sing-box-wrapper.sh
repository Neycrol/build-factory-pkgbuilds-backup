#!/bin/bash
# sing-box wrapper script with subconverter integration

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"

case "$1" in
    run)
        exec sing-box run -c "$CONFIG_FILE"
        ;;
    check)
        sing-box check -c "$CONFIG_FILE"
        ;;
    format)
        sing-box format -c "$CONFIG_FILE" -w
        ;;
    *)
        exec sing-box "$@"
        ;;
esac
