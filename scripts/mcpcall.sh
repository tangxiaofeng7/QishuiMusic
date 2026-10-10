#!/bin/sh
# ios-mcp helper on phone: $1 = tool name, $2 = JSON args (or empty)
H="Mcp-Session-Id: 395F568A-E3EC-40D0-AF35-C1E6BFCA86AC"
URL=http://127.0.0.1:8090/mcp
if [ "$1" = screenshot ]; then
  curl -s -X POST "$URL" -H "$H" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}' \
    | sed -n 's/.*"data":"\([^"]*\)".*/\1/p' | tr -d '\\' | base64 -d > /tmp/shot.jpg
  ls -la /tmp/shot.jpg
else
  curl -s -X POST "$URL" -H "$H" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"
  echo
fi
