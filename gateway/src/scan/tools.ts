// Definitions only: bundled into the `nuo` MCP server, which forwards each call to the gateway
// (POST /api/scan/tools/:name with its local token).

export const SCAN_TOOLS = [
  {
    name: "parcel_track",
    description:
      "Tracks a parcel from its tracking number (Colissimo, Chronopost, La Poste, UPS, DHL, DPD, GLS, Mondial Relay, Amazon, AliExpress…): adds it to the user's \"Colis\" collection, queries the carrier and returns a ::parcel card to copy as it is, alone on its line. The gateway then checks the parcel every 2 hours and notifies each change of status. A number already tracked is just updated (and renamed if label is given).",
    inputSchema: {
      type: "object",
      properties: {
        number: { type: "string", description: "Tracking number, as it is (spaces allowed)." },
        label: { type: "string", description: "Short label to tell it apart, in the user's language, e.g. \"Running shoes\"." },
      },
      required: ["number"],
    },
  },
  {
    name: "parcel_list",
    description: "Lists the tracked parcels: status, last event, expected delivery. By default those still on their way; all=true adds the delivered and returned ones.",
    inputSchema: { type: "object", properties: { all: { type: "boolean", description: "Include the delivered, returned or expired parcels." } } },
  },
  {
    name: "product_lookup",
    description:
      "Identifies a product by its barcode (EAN-13, EAN-8, UPC) in Open Food Facts then Open Beauty Facts. Food: returns the ::product card. Cosmetic: returns the ::cosmetic card with the score out of 100 and the risky ingredients (endocrine disruptors, allergens…). Copy the card as it is, alone on its line.",
    inputSchema: {
      type: "object",
      properties: {
        barcode: { type: "string", description: "Barcode, digits only." },
        kind: { type: "string", enum: ["food", "cosmetic"], description: "Only when the user said so; otherwise both bases are queried." },
      },
      required: ["barcode"],
    },
  },
] as const;

export const SCAN_TOOL_NAMES: ReadonlySet<string> = new Set(SCAN_TOOLS.map((t) => t.name));
