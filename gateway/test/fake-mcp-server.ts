// Tiny stdio MCP server for the slash command tests.
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";

const PNG_1PX = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

const server = new Server({ name: "fake", version: "0.0.1" }, { capabilities: { tools: {} } });
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    { name: "echo", inputSchema: { type: "object", properties: { flight_no: { type: "string" }, date: { type: "string" }, limit: { type: "number" } } } },
    { name: "chart", inputSchema: { type: "object", properties: {} } },
    { name: "fail", inputSchema: { type: "object", properties: {} } },
    { name: "env", inputSchema: { type: "object", properties: {} } },
  ],
}));
server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const args = req.params.arguments ?? {};
  switch (req.params.name) {
    case "echo":
      return { content: [{ type: "text", text: "args:" }, { type: "text", text: JSON.stringify(args) }] };
    case "chart":
      return { content: [{ type: "text", text: "Voici le graphique" }, { type: "image", data: PNG_1PX, mimeType: "image/png" }] };
    case "fail":
      return { content: [{ type: "text", text: "date invalide" }], isError: true };
    case "env":
      return { content: [{ type: "text", text: `${process.env.NUO_MEDIA_DIR}|${process.pid}` }] };
    default:
      throw new Error(`unknown tool ${req.params.name}`);
  }
});
await server.connect(new StdioServerTransport());
