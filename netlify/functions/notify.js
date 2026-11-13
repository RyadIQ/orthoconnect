// E-mails métier d'OrthoConnect, appelés par les Database Webhooks Supabase.
//
// POST /.netlify/functions/notify, en-tête x-webhook-secret obligatoire.
//   UPDATE praticiens, validation passée à 'valide'  : e-mail « compte validé » au praticien.
//   UPDATE praticiens, validation passée à 'refuse'  : e-mail de refus au praticien.
//   INSERT praticiens                                : alerte admin « nouvelle inscription ».
//   INSERT revendications                            : alerte admin « demande de fiche ».
//   Tout le reste                                    : 200, rien n'est envoyé.
//
// Variables d'environnement (Netlify, jamais dans le dépôt) : WEBHOOK_SECRET,
// SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, ADMIN_ALERT_EMAIL, SUPABASE_URL,
// SUPABASE_SERVICE_ROLE_KEY, EMAIL_DRY_RUN.
'use strict';

const crypto = require('crypto');
const nodemailer = require('nodemailer');

const SITE = 'https://orthoconnect.fr';
const EXPEDITEUR = 'OrthoConnect <contact@orthoconnect.fr>';
const REPONDRE_A = 'contact@orthoconnect.fr';

// ─────────── Sécurité ───────────

// Comparaison à temps constant, quelle que soit la longueur reçue : les
// deux valeurs sont d'abord ramenées à une empreinte de même taille.
function secretValide(recu, attendu) {
  if (!attendu || typeof recu !== 'string' || !recu) return false;
  const a = crypto.createHash('sha256').update(recu, 'utf8').digest();
  const b = crypto.createHash('sha256').update(attendu, 'utf8').digest();
  return crypto.timingSafeEqual(a, b);
}

// Toute valeur venant d'un utilisateur passe par ici avant d'entrer dans le HTML.
function esc(v) {
  return String(v == null ? '' : v)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// Un objet d'e-mail ne contient jamais de retour à la ligne (injection d'en-têtes).
function ligne(v) {
  return String(v == null ? '' : v).replace(/[\r\n\t]+/g, ' ').replace(/\s{2,}/g, ' ').trim();
}

function emailPlausible(v) {
  return typeof v === 'string' && v.length <= 254 && /^[^\s@<>"',;]+@[^\s@<>"',;]+\.[^\s@<>"',;]+$/.test(v);
}

const LIBELLES_STATUT = { liberal: 'Libéral', collaborateur: 'Collaborateur', interne: 'Interne' };

// ─────────── Mise en page (modèle Supabase v2, compatible Gmail mobile) ───────────

const P_TITRE = 'margin:0 0 16px 0;font-family:Arial,Helvetica,sans-serif;font-size:22px;line-height:28px;font-weight:bold;color:#0F2B4D;';
const P_TEXTE = 'margin:0 0 16px 0;font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:24px;color:#33475B;';
const P_PETIT = 'margin:0;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#33475B;';

function bouton(libelle, url) {
  return `<tr><td bgcolor="#FFFFFF" align="center" style="background-color:#FFFFFF;padding:8px 28px 24px 28px;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0" align="center" style="margin:0 auto;">
<tr><td align="center" bgcolor="#00B4C6" style="background-color:#00B4C6;border-radius:8px;">
<a href="${esc(url)}" target="_blank" style="display:block;padding:16px 32px;font-family:Arial,Helvetica,sans-serif;font-size:17px;line-height:20px;font-weight:bold;color:#0F2B4D;text-decoration:none;border-radius:8px;">${esc(libelle)}</a>
</td></tr>
</table>
</td></tr>`;
}

// corps : HTML déjà échappé, entre le bandeau et le pied. suite : lignes de tableau optionnelles (bouton, fin).
function page(titreDocument, corps, suite) {
  return `<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light only">
<title>${esc(titreDocument)}</title>
</head>
<body style="margin:0;padding:0;background-color:#EEF3F7;" bgcolor="#EEF3F7">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#EEF3F7" style="background-color:#EEF3F7;">
<tr><td align="center" style="padding:24px 12px;">
<table role="presentation" width="560" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:560px;">
<tr><td bgcolor="#0F2B4D" align="center" style="background-color:#0F2B4D;padding:28px 24px;">
<span style="font-family:Arial,Helvetica,sans-serif;font-size:26px;font-weight:bold;line-height:30px;color:#FFFFFF;">Ortho<span style="color:#00B4C6;">Connect</span></span>
</td></tr>
<tr><td bgcolor="#FFFFFF" style="background-color:#FFFFFF;padding:32px 28px 8px 28px;font-family:Arial,Helvetica,sans-serif;color:#0F2B4D;">
${corps}
</td></tr>
${suite || ''}
<tr><td bgcolor="#F7FAFC" align="center" style="background-color:#F7FAFC;padding:18px 24px;border-top:1px solid #E1E8EF;font-family:Arial,Helvetica,sans-serif;font-size:13px;line-height:19px;color:#6B7C8F;">
L'équipe OrthoConnect<br>contact@orthoconnect.fr
</td></tr>
</table>
</td></tr>
</table>
</body>
</html>`;
}

function bonjour(nom) {
  const n = ligne(nom);
  return n ? `Bonjour ${n},` : 'Bonjour,';
}

// ─────────── Les quatre e-mails ───────────

function mailCompteValide(p) {
  const objet = 'Votre compte OrthoConnect est validé';
  const html = page(objet,
    `<p style="${P_TITRE}">Votre compte est validé</p>
<p style="${P_TEXTE}">${esc(bonjour(p.nom))}</p>
<p style="margin:0;font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:24px;color:#33475B;">Nous avons vérifié votre identité : votre espace praticien est ouvert. Si vous avez demandé à reprendre une fiche de l'annuaire, elle est maintenant liée à votre compte.</p>`,
    bouton('Accéder à mon espace', SITE + '/mon-espace')
    + `\n<tr><td bgcolor="#FFFFFF" style="background-color:#FFFFFF;padding:0 28px 28px 28px;font-family:Arial,Helvetica,sans-serif;">
<p style="${P_PETIT}">Pensez à compléter la partie Mon cabinet de votre fiche. Une question ? Répondez simplement à ce message.</p>
</td></tr>`);
  const texte = `${bonjour(p.nom)}

Nous avons vérifié votre identité : votre espace praticien est ouvert. Si vous avez demandé à reprendre une fiche de l'annuaire, elle est maintenant liée à votre compte.

Accéder à mon espace : ${SITE}/mon-espace

Pensez à compléter la partie Mon cabinet de votre fiche. Une question ? Répondez simplement à ce message.

L'équipe OrthoConnect
contact@orthoconnect.fr`;
  return { objet, html, texte };
}

function mailCompteRefuse(p) {
  const objet = "Votre demande d'inscription OrthoConnect";
  const html = page(objet,
    `<p style="${P_TITRE}">Votre demande d'inscription</p>
<p style="${P_TEXTE}">${esc(bonjour(p.nom))}</p>
<p style="${P_TEXTE}">Nous n'avons pas pu vérifier votre identité professionnelle à partir des informations transmises, votre compte n'a donc pas été ouvert.</p>
<p style="margin:0 0 20px 0;font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:24px;color:#33475B;">Si vous pensez qu'il s'agit d'une erreur, répondez à ce message en indiquant votre numéro RPPS et un numéro où vous joindre.</p>`);
  const texte = `${bonjour(p.nom)}

Nous n'avons pas pu vérifier votre identité professionnelle à partir des informations transmises, votre compte n'a donc pas été ouvert.

Si vous pensez qu'il s'agit d'une erreur, répondez à ce message en indiquant votre numéro RPPS et un numéro où vous joindre.

L'équipe OrthoConnect
contact@orthoconnect.fr`;
  return { objet, html, texte };
}

// Alerte admin : sobre, une liste de champs et un lien.
function mailAlerte(type, p) {
  const nom = ligne(p.nom) || 'Nom non renseigné';
  const inscription = type === 'inscription';
  const objet = (inscription ? '[OrthoConnect] Nouvelle inscription : ' : '[OrthoConnect] Demande de fiche : ') + nom;
  const intro = inscription
    ? 'Nouvelle inscription (e-mail à confirmer)'
    : 'Nouvelle demande de fiche de l\'annuaire';
  const champs = [
    ['Nom', p.nom], ['Ville', p.ville], ['Statut', LIBELLES_STATUT[p.statut] || p.statut],
    ['RPPS', p.rpps], ['Téléphone', p.telephone], ['E-mail', p.email]
  ];
  if (!inscription && p.fiche_id) champs.push(['Fiche demandée', p.fiche_id]);
  const lignes = champs.map(([k, v]) => `<tr>
<td valign="top" style="padding:6px 12px 6px 0;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:20px;color:#6B7C8F;white-space:nowrap;">${esc(k)}</td>
<td valign="top" style="padding:6px 0;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:20px;color:#0F2B4D;word-break:break-word;">${v ? esc(ligne(v)) : '<span style="color:#6B7C8F;">non renseigné</span>'}</td>
</tr>`).join('\n');
  const html = page(objet,
    `<p style="margin:0 0 12px 0;font-family:Arial,Helvetica,sans-serif;font-size:18px;line-height:24px;font-weight:bold;color:#0F2B4D;">${esc(intro)}</p>
<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 20px 0;">
${lignes}
</table>
<p style="margin:0 0 24px 0;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#33475B;">À valider dans l'espace admin : <a href="${SITE}/mon-espace" target="_blank" style="color:#0A8F9E;text-decoration:underline;">${SITE.replace('https://', '')}/mon-espace</a></p>`);
  const texte = `${intro}

${champs.map(([k, v]) => `${k} : ${v ? ligne(v) : 'non renseigné'}`).join('\n')}

À valider dans l'espace admin : ${SITE}/mon-espace`;
  return { objet, html, texte };
}

// ─────────── Données ───────────

// Lecture du praticien d'une demande de fiche, avec la clé service role
// (côté serveur uniquement). null si la lecture échoue.
async function lirePraticien(id) {
  const url = process.env.SUPABASE_URL, cle = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !cle || !id) return null;
  try {
    const r = await fetch(`${url.replace(/\/+$/, '')}/rest/v1/praticiens?id=eq.${encodeURIComponent(id)}&select=id,nom,email,ville,statut,rpps,telephone`,
      { headers: { apikey: cle, Authorization: `Bearer ${cle}`, Accept: 'application/json' } });
    if (!r.ok) { console.error('notify : lecture du praticien refusée', { statut: r.status }); return null; }
    const lignes = await r.json();
    return Array.isArray(lignes) && lignes[0] ? lignes[0] : null;
  } catch (e) {
    console.error('notify : lecture du praticien impossible', { erreur: e && e.name });
    return null;
  }
}

// ─────────── Décision ───────────

// Ce qu'il faut envoyer pour ce payload : { action, a, message } ou { action: null }.
async function decider(payload) {
  const type = payload && payload.type;
  const table = payload && payload.table;
  const record = (payload && payload.record) || {};
  const ancien = (payload && payload.old_record) || {};

  if (table === 'praticiens' && type === 'UPDATE' && ancien.validation !== record.validation) {
    if (record.validation === 'valide') return { action: 'compte_valide', a: record.email, message: mailCompteValide(record) };
    if (record.validation === 'refuse') return { action: 'compte_refuse', a: record.email, message: mailCompteRefuse(record) };
    return { action: null };
  }
  if (table === 'praticiens' && type === 'INSERT') {
    return { action: 'alerte_inscription', a: process.env.ADMIN_ALERT_EMAIL, message: mailAlerte('inscription', record) };
  }
  if (table === 'revendications' && type === 'INSERT') {
    const p = await lirePraticien(record.praticien_id);
    const infos = Object.assign({ nom: null, ville: null, statut: null, rpps: record.rpps || null, telephone: null, email: null }, p || {});
    if (!infos.rpps) infos.rpps = record.rpps || null;
    infos.fiche_id = record.fiche_id || null;
    return { action: 'alerte_revendication', a: process.env.ADMIN_ALERT_EMAIL, message: mailAlerte('revendication', infos), praticienLu: !!p };
  }
  return { action: null };
}

// ─────────── Envoi ───────────

let transport = null;
function transporteur() {
  if (!transport) {
    const port = Number(process.env.SMTP_PORT || 465);
    transport = nodemailer.createTransport({
      host: process.env.SMTP_HOST, port, secure: port === 465,
      auth: { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS },
      connectionTimeout: 8000, greetingTimeout: 8000, socketTimeout: 10000
    });
  }
  return transport;
}

const reponse = (statusCode, corps) => ({ statusCode, headers: { 'content-type': 'application/json; charset=utf-8' }, body: JSON.stringify(corps) });

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') return reponse(405, { ok: false });

  const entetes = Object.fromEntries(Object.entries(event.headers || {}).map(([k, v]) => [k.toLowerCase(), v]));
  if (!process.env.WEBHOOK_SECRET) console.error('notify : WEBHOOK_SECRET absent, toutes les requêtes sont refusées');
  if (!secretValide(entetes['x-webhook-secret'], process.env.WEBHOOK_SECRET)) return reponse(401, { ok: false });

  let payload;
  try {
    const brut = event.isBase64Encoded ? Buffer.from(event.body || '', 'base64').toString('utf8') : (event.body || '');
    payload = JSON.parse(brut);
  } catch (e) {
    return reponse(400, { ok: false });
  }

  const d = await decider(payload);
  if (!d.action) return reponse(200, { ok: true, action: null });

  if (!emailPlausible(d.a)) {
    // Rien à qui écrire : journalisé, pas d'échec côté webhook pour un compte sans adresse.
    console.error('notify : destinataire absent ou invalide, rien n\'est envoyé', { action: d.action, admin: d.action.startsWith('alerte') });
    return d.action.startsWith('alerte') ? reponse(500, { ok: false }) : reponse(200, { ok: true, action: d.action, envoye: false });
  }

  const mail = { from: EXPEDITEUR, replyTo: REPONDRE_A, to: d.a, subject: ligne(d.message.objet), text: d.message.texte, html: d.message.html };

  if (String(process.env.EMAIL_DRY_RUN).toLowerCase() === 'true') {
    console.log('notify : mode test, rien n\'est envoyé', JSON.stringify({ action: d.action, from: mail.from, replyTo: mail.replyTo, to: mail.to,
      subject: mail.subject, smtp: { host: process.env.SMTP_HOST, port: process.env.SMTP_PORT, user: process.env.SMTP_USER }, texte: mail.text }));
    return reponse(200, { ok: true, action: d.action, dry_run: true });
  }

  try {
    const info = await transporteur().sendMail(mail);
    console.log('notify : envoyé', JSON.stringify({ action: d.action, messageId: info && info.messageId }));
    return reponse(200, { ok: true, action: d.action });
  } catch (e) {
    // Journalisé sans identifiants ; la réponse ne dit rien du détail.
    console.error('notify : envoi échoué', JSON.stringify({ action: d.action, code: e && e.code, commande: e && e.command, reponse: e && e.responseCode }));
    return reponse(500, { ok: false });
  }
};

// Pour les tests locaux uniquement.
exports._interne = { secretValide, esc, decider, mailCompteValide, mailCompteRefuse, mailAlerte };
