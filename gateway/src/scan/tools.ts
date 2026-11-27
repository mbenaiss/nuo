// Definitions only: bundled into the `nuo` MCP server, which forwards each call to the gateway
// (POST /api/scan/tools/:name with its local token).

export const SCAN_TOOLS = [
  {
    name: "parcel_track",
    description:
      "Suit un colis à partir de son numéro de suivi (Colissimo, Chronopost, La Poste, UPS, DHL, DPD, GLS, Mondial Relay, Amazon, AliExpress…) : l'ajoute à la collection « Colis » de l'utilisateur, interroge le transporteur et renvoie une carte ::parcel à recopier telle quelle, seule sur sa ligne. La passerelle vérifie ensuite le colis toutes les 2 heures et notifie chaque changement de statut. Un numéro déjà suivi est simplement mis à jour (et renommé si label est donné).",
    inputSchema: {
      type: "object",
      properties: {
        number: { type: "string", description: "Numéro de suivi, tel quel (espaces permis)." },
        label: { type: "string", description: "Libellé court pour s'y retrouver, ex. « Chaussures Decathlon »." },
      },
      required: ["number"],
    },
  },
  {
    name: "parcel_list",
    description: "Liste les colis suivis : statut, dernier événement, livraison prévue. Par défaut ceux encore en route ; all=true ajoute les livrés et retournés.",
    inputSchema: { type: "object", properties: { all: { type: "boolean", description: "Inclure les colis livrés, retournés ou expirés." } } },
  },
  {
    name: "product_lookup",
    description:
      "Identifie un produit par son code-barres (EAN-13, EAN-8, UPC) dans Open Food Facts puis Open Beauty Facts. Aliment : renvoie la carte ::product. Cosmétique : renvoie la carte ::cosmetic avec la note sur 100 et les ingrédients à risque (perturbateurs endocriniens, allergènes…). Recopie la carte telle quelle, seule sur sa ligne.",
    inputSchema: {
      type: "object",
      properties: {
        barcode: { type: "string", description: "Code-barres, chiffres uniquement." },
        kind: { type: "string", enum: ["food", "cosmetic"], description: "À préciser seulement si l'utilisateur l'a dit ; sinon les deux bases sont interrogées." },
      },
      required: ["barcode"],
    },
  },
] as const;

export const SCAN_TOOL_NAMES: ReadonlySet<string> = new Set(SCAN_TOOLS.map((t) => t.name));
