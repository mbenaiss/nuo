/** English is the source text and the default; French is kept for devices set to French. */
const FRENCH: Record<string, string> = {
  "Text": "Texte",
  "Write plain text": "Écrire du texte simple",
  "Heading 1": "Titre 1",
  "Big section heading": "Grand titre de section",
  "Heading 2": "Titre 2",
  "Medium heading": "Titre moyen",
  "Heading 3": "Titre 3",
  "Small heading": "Petit titre",
  "Bulleted list": "Liste à puces",
  "A simple list": "Une liste simple",
  "Numbered list": "Liste numérotée",
  "A list with numbers": "Une liste avec des numéros",
  "To-do list": "Liste de tâches",
  "Checkboxes": "Des cases à cocher",
  "Toggle": "Bascule",
  "Collapsible content": "Contenu repliable",
  "Quote": "Citation",
  "Highlight a quote": "Mettre une citation en avant",
  "Callout": "Encadré",
  "A colored block with an icon": "Un bloc coloré avec une icône",
  "Code block": "Bloc de code",
  "Code or plain text": "Du code ou du texte brut",
  "Divider": "Séparateur",
  "A separating line": "Une ligne de séparation",
  "Table": "Tableau",
  "A 3 × 3 table": "Un tableau de 3 × 3",
  "Upload or paste a link": "Importer ou coller un lien",
  "File": "Fichier",
  "Attach any file": "Joindre n'importe quel fichier",
  "Show a PDF": "Afficher un PDF",
  "Video": "Vidéo",
  "Attach a video": "Joindre une vidéo",
  "Attach a sound": "Joindre un son",
  "Embed a link": "Intégrer un lien",
  "A card pointing to a site": "Une carte vers un site",
  "Link": "Lien",
  "A link in the text": "Un lien dans le texte",
  "Link to a document": "Lien vers un document",
  "Mention another document": "Mentionner un autre document",
  "Today's date": "Date du jour",
  "Insert today's date": "Insérer la date d'aujourd'hui",
  "Diagram": "Schéma",
  "A Mermaid diagram: steps, schedule, org chart": "Un diagramme Mermaid : étapes, planning, organigramme",
  "Equation": "Équation",
  "A math formula (LaTeX)": "Une formule mathématique (LaTeX)",
  "Basic blocks": "Blocs de base",
  "Media": "Médias",
  "Other": "Autres",
  "Heading {0}": "Titre {0}",
  "Toggle title": "Titre de la bascule",
  "Write, or type “/” for commands": "Écris, ou tape « / » pour les commandes",
  "Write, or tap + to add a block": "Écris, ou touche + pour ajouter un bloc",
  "“{0}” is over 50 MB.": "« {0} » dépasse 50 Mo.",
  "file": "fichier",
  "Couldn't read “{0}”.": "Impossible de lire « {0} ».",
  "Uploading {0}…": "Envoi de {0}…",
  "{0} B": "{0} o",
  "{0} KB": "{0} Ko",
  "{0} MB": "{0} Mo",
  "Paste a link…": "Coller un lien…",
  "Upload from this device": "Importer depuis cet appareil",
  "Delete": "Supprimer",
  "or": "ou",
  "Resize": "Redimensionner",
  "Add a caption": "Ajouter une légende",
  "Play": "Lire",
  "Open": "Ouvrir",
  "Paste a link (site, video, document…)": "Coller un lien (site, vidéo, document…)",
  "Change the icon": "Changer l'icône",
  "No icon": "Sans icône",
  "Unreadable diagram: {0}": "Diagramme illisible : {0}",
  "Gray": "Gris",
  "Brown": "Marron",
  "Yellow": "Jaune",
  "Green": "Vert",
  "Blue": "Bleu",
  "Purple": "Violet",
  "Pink": "Rose",
  "Red": "Rouge",
  "No results": "Aucun résultat",
  "Callout color": "Couleur de l'encadré",
  "Text color": "Couleur du texte",
  "Background color": "Couleur de fond",
  "Default": "Par défaut",
  "Paste or type a link": "Coller ou écrire un lien",
  "Link text": "Texte du lien",
  "Remove link": "Retirer le lien",
  "Search for a document": "Chercher un document",
  "No documents": "Aucun document",
  "Underline (⌘U)": "Souligné (⌘U)",
  "Bold (⌘B)": "Gras (⌘B)",
  "Italic (⌘I)": "Italique (⌘I)",
  "Strikethrough (⌘⇧S)": "Barré (⌘⇧S)",
  "Link (⌘K)": "Lien (⌘K)",
  "Color": "Couleur",
  "Add a block below": "Ajouter un bloc en dessous",
  "Drag to move\nClick to open the menu": "Glisser pour déplacer\nCliquer pour ouvrir le menu",
  "Turn into": "Transformer en",
  "Duplicate": "Dupliquer",
  "Move up": "Monter",
  "Move down": "Descendre",
  "Block options": "Options du bloc",
};

export type Language = "en" | "fr";

export function languageOf(tag: string | undefined): Language {
  return /^fr(?:[-_]|$)/i.test(tag ?? "") ? "fr" : "en";
}

let current: Language = languageOf(typeof navigator === "undefined" ? undefined : navigator.language);

export function setLanguage(language: Language) {
  current = language;
}

/** BCP 47 tag for dates and numbers, matching the language of the texts. */
export function locale(): string {
  return current === "fr" ? "fr-FR" : "en-US";
}

/** The text for `key` (its English wording), with `{0}`, `{1}`... replaced by `values`. */
export function t(key: string, ...values: (string | number)[]): string {
  const text = (current === "fr" ? FRENCH[key] : undefined) ?? key;
  return values.length ? text.replace(/\{(\d+)\}/g, (match, index) => String(values[Number(index)] ?? match)) : text;
}
