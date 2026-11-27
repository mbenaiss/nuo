/**
 * The two pages Google requires before an OAuth app with restricted scopes can leave "Testing"
 * (docs/protocol.md, Google accounts). They are served by the public booking host, which is the
 * only hostname reachable without Cloudflare Access.
 */

export const LEGAL_UPDATED = "2026-11-20";

export interface LegalOptions {
  /** NUO_BOOKING_OWNER; shown as the operator of the service. */
  ownerName?: string;
  /** NUO_LEGAL_CONTACT; left unset, the pages carry no contact line (the consent screen already shows Google's support address). */
  contactEmail?: string;
}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

const frenchDate = (iso: string) => {
  const months = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"];
  const [y, m, d] = iso.split("-").map(Number);
  return `${d} ${months[(m ?? 1) - 1]} ${y}`;
};

const operator = (o: LegalOptions) => esc(o.ownerName ?? "l'éditeur de Nuo");

function contact(o: LegalOptions): string {
  if (!o.contactEmail) return "";
  const a = esc(o.contactEmail);
  return `<h2>Contact</h2>
<p>Pour toute question sur cette page ou sur les données traitées : <a href="mailto:${a}">${a}</a>.</p>`;
}

function privacyBody(o: LegalOptions): string {
  return `<h2>Qui exploite Nuo</h2>
<p>Nuo est un assistant personnel auto-hébergé, exploité par ${operator(o)} pour son usage privé. Il n'est pas ouvert au
public et ne fait l'objet d'aucune commercialisation. La passerelle tourne sur un serveur personnel ; il n'y a ni
hébergeur applicatif tiers, ni service d'analyse d'audience, ni régie publicitaire.</p>

<h2>Ce que Nuo lit dans votre compte Google</h2>
<p>Vous choisissez les services que vous connectez, et vous pouvez n'en connecter aucun. Chaque autorisation sert
uniquement à exécuter les demandes que vous formulez :</p>
<ul>
<li><strong>Gmail</strong> — rechercher, lire, rédiger et envoyer des messages lorsque vous le demandez, et classer ceux
que vous désignez.</li>
<li><strong>Drive</strong> — rechercher et lire les documents que vous demandez, et y écrire les fichiers que vous
faites produire.</li>
<li><strong>Agenda</strong> — lire vos évènements pour calculer vos disponibilités, créer et supprimer les rendez-vous
que vous validez.</li>
<li><strong>Identité</strong> (<code>openid</code>, adresse e-mail) — savoir quel compte est connecté et l'afficher dans
l'application.</li>
</ul>

<h2>Où vont ces données</h2>
<ul>
<li>Le jeton qui permet à Nuo d'agir en votre nom est chiffré (AES-256-GCM, clé propre au serveur) dans une base locale
lisible par le seul compte système de la passerelle. Il ne quitte jamais le serveur.</li>
<li>Les contenus Google ne sont pas recopiés dans une base : ils sont lus au moment de la demande et renvoyés dans la
réponse. En revanche, les réponses restent dans l'historique de la conversation, conservé sur le serveur jusqu'à ce que
vous l'effaciez.</li>
<li>Les assistants n'ont jamais accès au jeton lui-même : ils passent par la passerelle, qui exécute l'appel et ne
retourne que le résultat.</li>
</ul>

<h2>Modèles d'intelligence artificielle</h2>
<p>Pour produire une réponse, Nuo s'appuie sur des modèles exploités par des tiers — selon l'assistant choisi :
Anthropic, OpenAI, Google ou xAI. La demande et les extraits nécessaires pour y répondre leur sont transmis, et sont
alors soumis aux conditions et aux durées de conservation de ces fournisseurs. Un échange qui ne touche pas à vos
données Google ne leur en transmet aucune.</p>

<h2>Utilisation limitée</h2>
<p>L'utilisation et le transfert par Nuo des informations reçues des API Google respectent la
<a href="https://developers.google.com/terms/api-services-user-data-policy" rel="noreferrer">Politique relative aux
données utilisateur des services API Google</a>, y compris ses exigences d'utilisation limitée. Ces informations ne
sont ni vendues, ni cédées, ni utilisées à des fins publicitaires, ni exploitées pour entraîner des modèles.</p>

<h2>Pages de réservation publiques</h2>
<p>Si vous prenez rendez-vous depuis une page publique, Nuo enregistre les informations que vous saisissez — nom,
adresse e-mail, réponses aux questions du formulaire — ainsi que votre adresse IP, le temps nécessaire à la tenue du
rendez-vous et à la protection du formulaire contre les envois automatisés.</p>

<h2>Conservation et retrait</h2>
<p>Vous pouvez à tout moment déconnecter un compte depuis l'application : le jeton est alors révoqué auprès de Google
puis supprimé du serveur. Le même retrait est possible depuis
<a href="https://myaccount.google.com/permissions" rel="noreferrer">la page des accès tiers de votre compte Google</a>.
Les conversations et les rendez-vous se suppriment depuis l'application.</p>

${contact(o)}`;
}

function termsBody(o: LegalOptions): string {
  return `<h2>Objet</h2>
<p>Nuo est un assistant personnel auto-hébergé, exploité par ${operator(o)}. Ces conditions encadrent son usage et
celui des pages de réservation publiques qu'il expose.</p>

<h2>Accès</h2>
<p>L'application est réservée à ${operator(o)} et aux personnes qu'il autorise nommément. Les appareils sont appairés un
à un et tout autre accès est refusé. Seules les pages de réservation sont publiques.</p>

<h2>Votre compte Google</h2>
<p>Connecter un compte Google est facultatif et révocable à tout moment. Vous restez responsable de ce que vous demandez
à l'assistant : un message envoyé, un fichier écrit ou un évènement supprimé l'est en votre nom. Le détail de ce qui est
lu et conservé figure dans la <a href="/privacy">politique de confidentialité</a>.</p>

<h2>Prise de rendez-vous</h2>
<p>Un créneau réservé depuis une page publique n'est confirmé qu'une fois affiché comme tel. Vous pouvez le déplacer ou
l'annuler depuis le lien reçu. Les envois automatisés et les réservations manifestement abusives peuvent être bloqués.</p>

<h2>Disponibilité</h2>
<p>Le service est fourni « en l'état », sans garantie de disponibilité, d'exactitude ni de conservation. Il tourne sur
une installation personnelle et peut être interrompu, modifié ou arrêté sans préavis. ${operator(o)} ne peut être tenu
responsable d'une perte de données ou d'un rendez-vous manqué.</p>

<h2>Évolution</h2>
<p>Ces conditions peuvent changer ; la date de dernière mise à jour en haut de page fait foi.</p>

<h2>Droit applicable</h2>
<p>Ces conditions sont soumises au droit français.</p>

${contact(o)}`;
}

export const LEGAL_PAGES: Record<string, { title: string; heading: string; body: (o: LegalOptions) => string }> = {
  "/privacy": { title: "Politique de confidentialité", heading: "Politique de confidentialité", body: privacyBody },
  "/terms": { title: "Conditions d'utilisation", heading: "Conditions d'utilisation", body: termsBody },
};

/** The <main> of a legal page, ready to drop into the public site's HTML shell. */
export function legalMain(path: string, o: LegalOptions): string | undefined {
  const page = LEGAL_PAGES[path];
  if (!page) return undefined;
  const other = path === "/privacy" ? { href: "/terms", label: "Conditions d'utilisation" } : { href: "/privacy", label: "Politique de confidentialité" };
  return `<main class="legal"><section class="panel">
<p class="brand">Nuo</p>
<h1>${esc(page.heading)}</h1>
<p class="updated">Dernière mise à jour : ${frenchDate(LEGAL_UPDATED)}</p>
${page.body(o)}
<p class="updated"><a href="${other.href}">${esc(other.label)}</a></p>
</section></main>`;
}
