-- owner-only
-- Example owner collections for the tests: a freelance studio's clients, invoices, URSSAF payments and transfers.

CREATE TABLE clients (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  notion_id TEXT UNIQUE,
  nom TEXT NOT NULL DEFAULT '',
  tjm REAL CHECK (tjm IS NULL OR tjm >= 0),
  id_client INTEGER,
  contact_email TEXT,
  cc TEXT,
  ref_externe TEXT,
  ref_externe_2025 TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  archived_at TEXT
);

CREATE TABLE factures (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  notion_id TEXT UNIQUE,
  titre TEXT NOT NULL DEFAULT '',
  numero INTEGER,
  jours REAL CHECK (jours IS NULL OR jours >= 0),
  societe TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(societe) AND json_type(societe) = 'array'),
  client_id TEXT REFERENCES clients(id),
  date_emission TEXT CHECK (date_emission IS NULL OR date(date_emission) IS date_emission),
  date_encaissement TEXT CHECK (date_encaissement IS NULL OR date(date_encaissement) IS date_encaissement),
  paye INTEGER NOT NULL DEFAULT 0 CHECK (paye IN (0,1)),
  tva_payee INTEGER NOT NULL DEFAULT 0 CHECK (tva_payee IN (0,1)),
  pdf TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(pdf) AND json_type(pdf) = 'array'),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  archived_at TEXT
);
CREATE INDEX factures_client ON factures(client_id);

CREATE TABLE urssaf (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  notion_id TEXT UNIQUE,
  periode TEXT NOT NULL DEFAULT '',
  montant_du REAL,
  date_limite TEXT CHECK (date_limite IS NULL OR date(date_limite) IS date_limite),
  paye INTEGER NOT NULL DEFAULT 0 CHECK (paye IN (0,1)),
  annee INTEGER,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  archived_at TEXT
);

CREATE TABLE virements (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  notion_id TEXT UNIQUE,
  commentaire TEXT NOT NULL DEFAULT '',
  date TEXT CHECK (date IS NULL OR date(date) IS date),
  montant REAL,
  exercice INTEGER,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  archived_at TEXT
);

-- Notion: Année = last word of the title ("Septembre 2026" -> 2026); Mois = month(Facturé) or 0;
-- CA_HT = Jrs * Client.at(0).TJM; TVA = CA_HT * 20 / 100; TTC = CA_HT + TVA.
CREATE VIEW v_factures AS
SELECT f.*,
  c.nom AS client,
  c.tjm AS tjm,
  round(f.jours * c.tjm, 2) AS ca_ht,
  round(f.jours * c.tjm * 20 / 100, 2) AS tva,
  round(f.jours * c.tjm * 120 / 100, 2) AS ttc,
  CAST(NULLIF(trim(substr(f.titre, length(rtrim(f.titre, replace(f.titre, ' ', ''))) + 1)), '') AS INTEGER) AS annee,
  CASE WHEN f.date_emission IS NULL THEN 0 ELSE CAST(strftime('%m', f.date_emission) AS INTEGER) END AS mois,
  'Bonjour,' || char(10) || char(10) || 'Veuillez trouver en pièce jointe la facture relative au mois de '
    || CASE WHEN trim(f.titre) = '' THEN '[DATE]' ELSE lower(f.titre) END
    || '.' || char(10) || char(10) || 'Je reste à votre disposition pour tout renseignement complémentaire.'
    || char(10) || char(10) || 'Cordialement,' AS texte
FROM factures f
LEFT JOIN clients c ON c.id = f.client_id;

CREATE VIEW v_clients AS
SELECT c.*,
  (SELECT count(*) FROM factures f WHERE f.client_id = c.id AND f.archived_at IS NULL) AS nb_factures,
  (SELECT round(sum(f.jours * c.tjm), 2) FROM factures f WHERE f.client_id = c.id AND f.archived_at IS NULL) AS ca_ht_total
FROM clients c;

CREATE VIEW v_urssaf AS SELECT * FROM urssaf;

-- Notion: Impôts = Montant * 17.8 / 100; Montant Net = Montant - Impôts;
-- Mensualisé (Net) = Montant (Net) / (month(now()) if Exercice is the current year, else 12).
CREATE VIEW v_virements AS
SELECT v.*,
  round(v.montant * 17.8 / 100, 2) AS impots,
  round(v.montant - v.montant * 17.8 / 100, 2) AS montant_net,
  round(v.montant / (CASE WHEN v.exercice = CAST(strftime('%Y', 'now', 'localtime') AS INTEGER)
    THEN CAST(strftime('%m', 'now', 'localtime') AS INTEGER) ELSE 12 END), 2) AS mensualise,
  round((v.montant - v.montant * 17.8 / 100) / (CASE WHEN v.exercice = CAST(strftime('%Y', 'now', 'localtime') AS INTEGER)
    THEN CAST(strftime('%m', 'now', 'localtime') AS INTEGER) ELSE 12 END), 2) AS mensualise_net,
  CAST(strftime('%m', v.date) AS INTEGER) AS mois
FROM virements v;

INSERT INTO _collections (id, label, emoji, table_name, view_name, title_column, default_sort, notion_slug, position) VALUES
  ('factures', 'Factures', '🧾', 'factures', 'v_factures', 'titre', 'numero:desc', 'factures', 10),
  ('clients', 'Clients', '🤝', 'clients', 'v_clients', 'nom', 'nom:asc', 'clients', 11),
  ('virements', 'Virements', '💸', 'virements', 'v_virements', 'commentaire', 'date:desc', 'virements', 12),
  ('urssaf', 'URSSAF', '🏛️', 'urssaf', 'v_urssaf', 'periode', 'date_limite:desc', 'urssaf', 13);

INSERT INTO _columns (collection_id, name, label, type, options, ref_collection, computed, hidden, position, notion_name) VALUES
  ('clients', 'nom', 'Client', 'text', NULL, NULL, 0, 0, 1, 'Client'),
  ('clients', 'tjm', 'TJM', 'money', NULL, NULL, 0, 0, 2, 'TJM'),
  ('clients', 'id_client', 'ID client', 'number', NULL, NULL, 0, 0, 3, 'ID CLient'),
  ('clients', 'contact_email', 'Email', 'text', NULL, NULL, 0, 0, 4, 'Contact Email'),
  ('clients', 'cc', 'CC', 'text', NULL, NULL, 0, 0, 5, 'CC'),
  ('clients', 'ref_externe', 'Réf. externe', 'text', NULL, NULL, 0, 0, 6, 'Ref Externe'),
  ('clients', 'ref_externe_2025', 'Réf. externe 2025', 'text', NULL, NULL, 0, 1, 7, 'Ref Externe 2025'),
  ('clients', 'nb_factures', 'Factures', 'number', NULL, NULL, 1, 0, 8, NULL),
  ('clients', 'ca_ht_total', 'CA HT total', 'money', NULL, NULL, 1, 0, 9, NULL),

  ('factures', 'titre', 'Mois facturé', 'text', NULL, NULL, 0, 0, 1, 'Date'),
  ('factures', 'numero', 'N°', 'number', NULL, NULL, 0, 0, 2, 'Facture'),
  ('factures', 'client_id', 'Client', 'ref', NULL, 'clients', 0, 0, 3, 'Client'),
  ('factures', 'client', 'Nom client', 'text', NULL, NULL, 1, 1, 4, NULL),
  ('factures', 'jours', 'Jours', 'number', NULL, NULL, 0, 0, 5, 'Jrs'),
  ('factures', 'societe', 'Société', 'multiselect', '[]', NULL, 0, 0, 6, 'Société'),
  ('factures', 'tjm', 'TJM', 'money', NULL, NULL, 1, 1, 7, NULL),
  ('factures', 'ca_ht', 'CA HT', 'money', NULL, NULL, 1, 0, 8, 'CA_HT'),
  ('factures', 'tva', 'TVA', 'money', NULL, NULL, 1, 0, 9, 'TVA'),
  ('factures', 'ttc', 'TTC', 'money', NULL, NULL, 1, 0, 10, 'TTC'),
  ('factures', 'date_emission', 'Facturé le', 'date', NULL, NULL, 0, 0, 11, 'Facturé'),
  ('factures', 'date_encaissement', 'Encaissé le', 'date', NULL, NULL, 0, 0, 12, 'Encaissé'),
  ('factures', 'paye', 'Payé', 'bool', NULL, NULL, 0, 0, 13, 'Payé'),
  ('factures', 'tva_payee', 'TVA payée', 'bool', NULL, NULL, 0, 0, 14, 'TVA Payé'),
  ('factures', 'annee', 'Année', 'number', NULL, NULL, 1, 0, 15, 'Année'),
  ('factures', 'mois', 'Mois', 'number', NULL, NULL, 1, 1, 16, 'Mois'),
  ('factures', 'pdf', 'PDF', 'file', NULL, NULL, 0, 0, 17, 'PDF'),
  ('factures', 'texte', 'Texte email', 'longtext', NULL, NULL, 1, 1, 18, 'Texte'),

  ('urssaf', 'periode', 'Période', 'text', NULL, NULL, 0, 0, 1, 'Période'),
  ('urssaf', 'montant_du', 'Montant dû', 'money', NULL, NULL, 0, 0, 2, 'Montant dû'),
  ('urssaf', 'date_limite', 'Date limite', 'date', NULL, NULL, 0, 0, 3, 'Date limite de paiement'),
  ('urssaf', 'paye', 'Payé', 'bool', NULL, NULL, 0, 0, 4, 'Payé'),
  ('urssaf', 'annee', 'Année', 'number', NULL, NULL, 0, 0, 5, 'Année'),

  ('virements', 'commentaire', 'Commentaire', 'text', NULL, NULL, 0, 0, 1, 'Commentaire'),
  ('virements', 'date', 'Date', 'date', NULL, NULL, 0, 0, 2, 'Date'),
  ('virements', 'montant', 'Montant', 'money', NULL, NULL, 0, 0, 3, 'Montant'),
  ('virements', 'exercice', 'Exercice', 'number', NULL, NULL, 0, 0, 4, 'Exercice'),
  ('virements', 'impots', 'Impôts', 'money', NULL, NULL, 1, 0, 5, 'Impôts'),
  ('virements', 'montant_net', 'Montant net', 'money', NULL, NULL, 1, 0, 6, 'Montant Net'),
  ('virements', 'mensualise', 'Mensualisé', 'money', NULL, NULL, 1, 0, 7, 'Mensualisé'),
  ('virements', 'mensualise_net', 'Mensualisé net', 'money', NULL, NULL, 1, 0, 8, 'Mensualisé Net'),
  ('virements', 'mois', 'Mois', 'number', NULL, NULL, 1, 1, 9, NULL);
