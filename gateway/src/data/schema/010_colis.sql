-- Tracked parcels (src/scan/parcels.ts): added from a scan, the /colis command or a bot, refreshed by the gateway.

CREATE TABLE colis (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  numero TEXT NOT NULL CHECK (length(numero) BETWEEN 6 AND 40),
  libelle TEXT,
  transporteur TEXT,
  transporteur_id TEXT,
  statut TEXT NOT NULL DEFAULT 'Inconnu',
  dernier_evenement TEXT,
  dernier_evenement_at TEXT,
  livraison_prevue TEXT CHECK (livraison_prevue IS NULL OR date(livraison_prevue) IS livraison_prevue),
  livre_at TEXT,
  lien TEXT,
  evenements TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(evenements) AND json_type(evenements) = 'array'),
  source TEXT,
  erreur TEXT,
  verifie_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  archived_at TEXT
);
CREATE UNIQUE INDEX colis_numero_actif ON colis(numero) WHERE archived_at IS NULL;

CREATE VIEW v_colis AS SELECT c.* FROM colis c;

INSERT INTO _collections (id, label, emoji, table_name, view_name, title_column, default_sort, position) VALUES
  ('colis', 'Colis', '📦', 'colis', 'v_colis', 'numero', 'created_at:desc', 60);

INSERT INTO _columns (collection_id, name, label, type, options, ref_collection, computed, hidden, position) VALUES
  ('colis', 'numero', 'N° de suivi', 'text', NULL, NULL, 0, 0, 1),
  ('colis', 'libelle', 'Libellé', 'text', NULL, NULL, 0, 0, 2),
  ('colis', 'statut', 'Statut', 'select', '[{"name":"En attente","color":"gray"},{"name":"Annoncé","color":"gray"},{"name":"En transit","color":"blue"},{"name":"En livraison","color":"purple"},{"name":"À retirer","color":"orange"},{"name":"Livré","color":"green"},{"name":"Incident","color":"red"},{"name":"Retourné","color":"brown"},{"name":"Expiré","color":"gray"},{"name":"Inconnu","color":"gray"}]', NULL, 0, 0, 3),
  ('colis', 'transporteur', 'Transporteur', 'text', NULL, NULL, 0, 0, 4),
  ('colis', 'dernier_evenement', 'Dernier événement', 'text', NULL, NULL, 0, 0, 5),
  ('colis', 'dernier_evenement_at', 'Le', 'datetime', NULL, NULL, 0, 0, 6),
  ('colis', 'livraison_prevue', 'Livraison prévue', 'date', NULL, NULL, 0, 0, 7),
  ('colis', 'livre_at', 'Livré le', 'datetime', NULL, NULL, 0, 0, 8),
  ('colis', 'lien', 'Suivi en ligne', 'url', NULL, NULL, 0, 0, 9),
  ('colis', 'evenements', 'Historique', 'longtext', NULL, NULL, 0, 1, 10),
  ('colis', 'transporteur_id', 'Code transporteur', 'text', NULL, NULL, 0, 1, 11),
  ('colis', 'source', 'Source du suivi', 'text', NULL, NULL, 0, 1, 12),
  ('colis', 'erreur', 'Erreur', 'text', NULL, NULL, 0, 1, 13),
  ('colis', 'verifie_at', 'Vérifié le', 'datetime', NULL, NULL, 0, 1, 14);
