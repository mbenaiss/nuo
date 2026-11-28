/**
 * The two pages Google requires before an OAuth app with restricted scopes can leave "Testing"
 * (docs/protocol.md, Google accounts). They are served by the public booking host, which is the
 * only hostname reachable without Cloudflare Access.
 */

import type { UiLanguage } from "../i18n/language";

export const LEGAL_UPDATED = "2026-11-20";

export interface LegalOptions {
  /** NUO_BOOKING_OWNER; shown as the operator of the service. */
  ownerName?: string;
  /** NUO_LEGAL_CONTACT; left unset, the pages carry no contact line (the consent screen already shows Google's support address). */
  contactEmail?: string;
}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

interface LegalTexts {
  operator: string;
  updated: (date: string) => string;
  contact: (link: string) => string;
  privacyTitle: string;
  termsTitle: string;
  privacy: (o: LegalOptions) => string;
  terms: (o: LegalOptions) => string;
}

const frenchDate = (iso: string) => {
  const months = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"];
  const [y, m, d] = iso.split("-").map(Number);
  return `${d} ${months[(m ?? 1) - 1]} ${y}`;
};

const englishDate = (iso: string) => new Intl.DateTimeFormat("en-US", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" }).format(new Date(`${iso}T00:00:00Z`));

const operator = (o: LegalOptions, texts: Pick<LegalTexts, "operator">) => esc(o.ownerName ?? texts.operator);

function contact(o: LegalOptions, texts: LegalTexts): string {
  if (!o.contactEmail) return "";
  const a = esc(o.contactEmail);
  return `<h2>Contact</h2>
<p>${texts.contact(`<a href="mailto:${a}">${a}</a>`)}</p>`;
}

const EN: LegalTexts = {
  operator: "the publisher of Nuo",
  updated: (date) => `Last updated: ${englishDate(date)}`,
  contact: (link) => `For any question about this page or the data processed: ${link}.`,
  privacyTitle: "Privacy policy",
  termsTitle: "Terms of use",
  privacy: (o) => `<h2>Who runs Nuo</h2>
<p>Nuo is a self-hosted personal assistant, run by ${operator(o, EN)} for private use. It is not open to the public and
is not sold. The gateway runs on a personal server; there is no third-party application host, no audience analytics
service and no advertising network.</p>

<h2>What Nuo reads in your Google account</h2>
<p>You choose the services you connect, and you may connect none. Each permission is used only to carry out the
requests you make:</p>
<ul>
<li><strong>Gmail</strong>: search, read, draft and send messages when you ask, and file the ones you point to.</li>
<li><strong>Drive</strong>: search and read the documents you ask for, and write there the files you have produced.</li>
<li><strong>Calendar</strong>: read your events to work out your availability, create and delete the appointments you
approve.</li>
<li><strong>Identity</strong> (<code>openid</code>, email address): know which account is connected and show it in the
app.</li>
</ul>

<h2>Where this data goes</h2>
<ul>
<li>The token that lets Nuo act on your behalf is encrypted (AES-256-GCM, with a key of the server's own) in a local
database readable only by the gateway's system account. It never leaves the server.</li>
<li>Google content is not copied into a database: it is read at the time of the request and returned in the answer.
The answers, however, stay in the conversation history, kept on the server until you delete it.</li>
<li>The assistants never get the token itself: they go through the gateway, which makes the call and returns only the
result.</li>
</ul>

<h2>Artificial intelligence models</h2>
<p>To produce an answer, Nuo relies on models run by third parties, depending on the assistant chosen: Anthropic,
OpenAI, Google or xAI. The request and the excerpts needed to answer it are sent to them, and are then subject to the
terms and retention periods of these providers. An exchange that does not touch your Google data sends them none of
it.</p>

<h2>Limited use</h2>
<p>Nuo's use and transfer of information received from Google APIs adheres to the
<a href="https://developers.google.com/terms/api-services-user-data-policy" rel="noreferrer">Google API Services User
Data Policy</a>, including the Limited Use requirements. This information is not sold, transferred, used for
advertising or used to train models.</p>

<h2>Public booking pages</h2>
<p>If you book an appointment from a public page, Nuo keeps the information you enter (name, email address, answers to
the form's questions) and your IP address, for as long as needed to hold the appointment and to protect the form
against automated submissions.</p>

<h2>Retention and removal</h2>
<p>You can disconnect an account from the app at any time: the token is then revoked with Google and deleted from the
server. The same removal is possible from
<a href="https://myaccount.google.com/permissions" rel="noreferrer">the third-party access page of your Google account</a>.
Conversations and appointments are deleted from the app.</p>

${contact(o, EN)}`,
  terms: (o) => `<h2>Purpose</h2>
<p>Nuo is a self-hosted personal assistant, run by ${operator(o, EN)}. These terms govern its use and that of the
public booking pages it serves.</p>

<h2>Access</h2>
<p>The app is reserved for ${operator(o, EN)} and the people they name. Devices are paired one by one and any other
access is refused. Only the booking pages are public.</p>

<h2>Your Google account</h2>
<p>Connecting a Google account is optional and can be undone at any time. You remain responsible for what you ask the
assistant: a message sent, a file written or an event deleted is done in your name. What is read and kept is detailed
in the <a href="/privacy">privacy policy</a>.</p>

<h2>Booking appointments</h2>
<p>A time slot booked from a public page is confirmed only once shown as such. You can reschedule or cancel it from the
link you receive. Automated submissions and clearly abusive bookings may be blocked.</p>

<h2>Availability</h2>
<p>The service is provided "as is", with no guarantee of availability, accuracy or retention. It runs on a personal
setup and may be interrupted, changed or stopped without notice. ${operator(o, EN)} cannot be held liable for lost data
or a missed appointment.</p>

<h2>Changes</h2>
<p>These terms may change; the date of the last update at the top of the page is authoritative.</p>

<h2>Governing law</h2>
<p>These terms are governed by French law.</p>

${contact(o, EN)}`,
};

const FR: LegalTexts = {
  operator: "l'éditeur de Nuo",
  updated: (date) => `Dernière mise à jour : ${frenchDate(date)}`,
  contact: (link) => `Pour toute question sur cette page ou sur les données traitées : ${link}.`,
  privacyTitle: "Politique de confidentialité",
  termsTitle: "Conditions d'utilisation",
  privacy: (o) => `<h2>Qui exploite Nuo</h2>
<p>Nuo est un assistant personnel auto-hébergé, exploité par ${operator(o, FR)} pour son usage privé. Il n'est pas ouvert au
public et ne fait l'objet d'aucune commercialisation. La passerelle tourne sur un serveur personnel ; il n'y a ni
hébergeur applicatif tiers, ni service d'analyse d'audience, ni régie publicitaire.</p>

<h2>Ce que Nuo lit dans votre compte Google</h2>
<p>Vous choisissez les services que vous connectez, et vous pouvez n'en connecter aucun. Chaque autorisation sert
uniquement à exécuter les demandes que vous formulez :</p>
<ul>
<li><strong>Gmail</strong> : rechercher, lire, rédiger et envoyer des messages lorsque vous le demandez, et classer ceux
que vous désignez.</li>
<li><strong>Drive</strong> : rechercher et lire les documents que vous demandez, et y écrire les fichiers que vous
faites produire.</li>
<li><strong>Agenda</strong> : lire vos évènements pour calculer vos disponibilités, créer et supprimer les rendez-vous
que vous validez.</li>
<li><strong>Identité</strong> (<code>openid</code>, adresse e-mail) : savoir quel compte est connecté et l'afficher dans
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
<p>Pour produire une réponse, Nuo s'appuie sur des modèles exploités par des tiers, selon l'assistant choisi :
Anthropic, OpenAI, Google ou xAI. La demande et les extraits nécessaires pour y répondre leur sont transmis, et sont
alors soumis aux conditions et aux durées de conservation de ces fournisseurs. Un échange qui ne touche pas à vos
données Google ne leur en transmet aucune.</p>

<h2>Utilisation limitée</h2>
<p>L'utilisation et le transfert par Nuo des informations reçues des API Google respectent la
<a href="https://developers.google.com/terms/api-services-user-data-policy" rel="noreferrer">Politique relative aux
données utilisateur des services API Google</a>, y compris ses exigences d'utilisation limitée. Ces informations ne
sont ni vendues, ni cédées, ni utilisées à des fins publicitaires, ni exploitées pour entraîner des modèles.</p>

<h2>Pages de réservation publiques</h2>
<p>Si vous prenez rendez-vous depuis une page publique, Nuo enregistre les informations que vous saisissez (nom,
adresse e-mail, réponses aux questions du formulaire), ainsi que votre adresse IP, le temps nécessaire à la tenue du
rendez-vous et à la protection du formulaire contre les envois automatisés.</p>

<h2>Conservation et retrait</h2>
<p>Vous pouvez à tout moment déconnecter un compte depuis l'application : le jeton est alors révoqué auprès de Google
puis supprimé du serveur. Le même retrait est possible depuis
<a href="https://myaccount.google.com/permissions" rel="noreferrer">la page des accès tiers de votre compte Google</a>.
Les conversations et les rendez-vous se suppriment depuis l'application.</p>

${contact(o, FR)}`,
  terms: (o) => `<h2>Objet</h2>
<p>Nuo est un assistant personnel auto-hébergé, exploité par ${operator(o, FR)}. Ces conditions encadrent son usage et
celui des pages de réservation publiques qu'il expose.</p>

<h2>Accès</h2>
<p>L'application est réservée à ${operator(o, FR)} et aux personnes qu'il autorise nommément. Les appareils sont appairés un
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
une installation personnelle et peut être interrompu, modifié ou arrêté sans préavis. ${operator(o, FR)} ne peut être tenu
responsable d'une perte de données ou d'un rendez-vous manqué.</p>

<h2>Évolution</h2>
<p>Ces conditions peuvent changer ; la date de dernière mise à jour en haut de page fait foi.</p>

<h2>Droit applicable</h2>
<p>Ces conditions sont soumises au droit français.</p>

${contact(o, FR)}`,
};

/** Legal wording is written per language, not assembled from the catalogs: a language without its own gets English. */
const TEXTS: Partial<Record<UiLanguage, LegalTexts>> = { en: EN, fr: FR };
const textsFor = (lang: UiLanguage) => TEXTS[lang] ?? EN;

/** The page's title, or undefined when `path` is not a legal page. */
export function legalTitle(path: string, lang: UiLanguage): string | undefined {
  const texts = textsFor(lang);
  return path === "/privacy" ? texts.privacyTitle : path === "/terms" ? texts.termsTitle : undefined;
}

/** The <main> of a legal page, ready to drop into the public site's HTML shell. */
export function legalMain(path: string, o: LegalOptions, lang: UiLanguage): string | undefined {
  const heading = legalTitle(path, lang);
  if (!heading) return undefined;
  const texts = textsFor(lang);
  const body = path === "/privacy" ? texts.privacy(o) : texts.terms(o);
  const other = path === "/privacy" ? { href: "/terms", label: texts.termsTitle } : { href: "/privacy", label: texts.privacyTitle };
  return `<main class="legal"><section class="panel">
<p class="brand">Nuo</p>
<h1>${esc(heading)}</h1>
<p class="updated">${texts.updated(LEGAL_UPDATED)}</p>
${body}
<p class="updated"><a href="${other.href}">${esc(other.label)}</a></p>
</section></main>`;
}
