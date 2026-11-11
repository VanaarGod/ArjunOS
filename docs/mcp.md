# MCP servers

One JSON file per server in `~/Library/Application Support/JarvisOS/state/mcp/` (Tools → MCP Servers → **Reveal folder**).

```json
{ "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/you/Documents"], "env": {} }
```
```json
{ "url": "https://example.com/mcp", "headers": { "Authorization": "Bearer …" } }
```
Optional: `"enabled": false`, `"description": "…"`. The file name is the server name (lowercase letters, digits, `-`, `_`).

- **Add** in the app (paste one server or a whole `{"mcpServers": …}` block → one file each), or drop a file in the folder and press **Reload**.
- **Approve:** nothing runs until you review the summary and warnings and approve that file. Editing command/args/env/url/headers revokes approval.
- **Use:** connected tools are offered to the model. Every call asks for your approval unless you switch on *Always allow* for that one tool.
- Transports: stdio and Streamable HTTP. Not implemented: legacy HTTP+SSE, OAuth for remote servers.
