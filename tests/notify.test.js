// Test local de netlify/functions/notify.js : node tests/notify.test.js
// Aucun secret réel : valeurs de test, Supabase simulé, SMTP local.
'use strict';
const assert = require('assert');
const net = require('net');
const fs = require('fs');
const path = require('path');

const SECRET = 'secret-de-test';
Object.assign(process.env, {
  WEBHOOK_SECRET: SECRET, EMAIL_DRY_RUN: 'true', ADMIN_ALERT_EMAIL: 'alertes@example.test',
  SMTP_HOST: 'smtp.example.test', SMTP_PORT: '465', SMTP_USER: 'contact@example.test', SMTP_PASS: 'mot-de-passe-de-test',
  SUPABASE_URL: 'https://projet.example.test', SUPABASE_SERVICE_ROLE_KEY: 'cle-service-de-test'
});

// Supabase simulé : la lecture d'un praticien par la clé service role.
const lectures = [];
global.fetch = async (url, opts) => {
  lectures.push({ url: String(url), auth: opts.headers.Authorization === 'Bearer cle-service-de-test' });
  if (String(url).includes('id=eq.u-baron')) return { ok: true, status: 200, json: async () => [{ id: 'u-baron', nom: 'PASCAL BARON', email: 'baron@example.test', ville: 'Paris', statut: 'liberal', rpps: '10001068732', telephone: '06 12 34 56 78' }] };
  return { ok: false, status: 404, json: async () => [] };
};

// Les journaux de la fonction, pour vérifier ce qui est écrit.
const journal = [];
const vrai = { log: console.log, error: console.error };
console.log = (...a) => journal.push(['log', a.join(' ')]);
console.error = (...a) => journal.push(['error', a.join(' ')]);

const { handler, _interne } = require('../netlify/functions/notify.js');
const appel = (corps, secret = SECRET, methode = 'POST') => handler({ httpMethod: methode, headers: secret === null ? {} : { 'X-Webhook-Secret': secret }, body: typeof corps === 'string' ? corps : JSON.stringify(corps) });

const praticien = (extra) => Object.assign({ id: 'u-baron', nom: 'PASCAL BARON', email: 'baron@example.test', ville: 'Paris', statut: 'liberal', rpps: '10001068732', telephone: '06 12 34 56 78', validation: 'en_attente' }, extra);
const CAS = [
  ['compte validé', { type: 'UPDATE', table: 'praticiens', schema: 'public', record: praticien({ validation: 'valide' }), old_record: praticien() }, 200, 'compte_valide'],
  ['compte refusé', { type: 'UPDATE', table: 'praticiens', schema: 'public', record: praticien({ validation: 'refuse' }), old_record: praticien() }, 200, 'compte_refuse'],
  ['nouvelle inscription', { type: 'INSERT', table: 'praticiens', schema: 'public', record: praticien(), old_record: null }, 200, 'alerte_inscription'],
  ['demande de fiche', { type: 'INSERT', table: 'revendications', schema: 'public', record: { id: 'r1', praticien_id: 'u-baron', rpps: '10001068732', fiche_id: 'fiche-1', statut: 'en_attente' }, old_record: null }, 200, 'alerte_revendication'],
  ['mauvais secret', { type: 'INSERT', table: 'praticiens', record: praticien() }, 401, undefined, 'faux'],
  ['sans secret', { type: 'INSERT', table: 'praticiens', record: praticien() }, 401, undefined, null],
  ['payload inconnu (DELETE)', { type: 'DELETE', table: 'praticiens', record: null, old_record: praticien() }, 200, null],
  ['UPDATE sans changement de validation', { type: 'UPDATE', table: 'praticiens', record: praticien({ ville: 'Lyon' }), old_record: praticien() }, 200, null],
  ['autre table', { type: 'INSERT', table: 'formations', record: { id: 1 } }, 200, null],
  ['JSON invalide', '{ pas du json', 400, undefined],
  ['méthode GET', {}, 405, undefined, SECRET, 'GET']
];

(async () => {
  const lignesResultat = [];
  for (const [nom, corps, statutAttendu, actionAttendue, secret = SECRET, methode = 'POST'] of CAS) {
    journal.length = 0;
    const r = await appel(corps, secret, methode);
    const b = JSON.parse(r.body);
    assert.strictEqual(r.statusCode, statutAttendu, nom);
    if (actionAttendue !== undefined) assert.strictEqual(b.action, actionAttendue, nom);
    const envoi = journal.find(j => j[1].startsWith('notify : mode test'));
    if (actionAttendue) {
      assert.ok(envoi, nom + ' : journal du mode test');
      assert.ok(!envoi[1].includes('mot-de-passe-de-test'), nom + ' : mot de passe absent du journal');
    } else assert.ok(!envoi, nom + ' : rien envoyé');
    const detail = envoi ? JSON.parse(envoi[1].slice(envoi[1].indexOf('{'))) : null;
    lignesResultat.push(`${nom.padEnd(38)} ${r.statusCode}  ${String(b.action === undefined ? '-' : b.action).padEnd(22)} ${detail ? detail.to + ' | ' + detail.subject : 'rien envoyé'}`);
  }

  // Nom contenant du HTML : échappé dans le HTML, sans retour à la ligne dans l'objet.
  journal.length = 0;
  const piege = 'Eve <img src=x onerror=alert(1)>\r\nBcc: pirate@example.test';
  const d = await _interne.decider({ type: 'INSERT', table: 'praticiens', record: praticien({ nom: piege, ville: '<script>alert(2)</script>' }) });
  assert.ok(!d.message.html.includes('<img src=x'), 'balise img échappée');
  assert.ok(!d.message.html.includes('<script>'), 'balise script échappée');
  assert.ok(d.message.html.includes('&lt;img src=x onerror=alert(1)&gt;'), 'nom visible, échappé');
  const rPiege = await appel({ type: 'INSERT', table: 'praticiens', record: praticien({ nom: piege }) });
  const envoiPiege = JSON.parse(journal.find(j => j[1].startsWith('notify : mode test'))[1].replace(/^[^{]*/, ''));
  assert.ok(!/[\r\n]/.test(envoiPiege.subject), 'objet sur une ligne');
  assert.strictEqual(envoiPiege.to, 'alertes@example.test', 'destinataire inchangé');
  lignesResultat.push(`${'nom contenant du HTML'.padEnd(38)} ${rPiege.statusCode}  ${'alerte_inscription'.padEnd(22)} objet : ${envoiPiege.subject}`);

  // Demande de fiche : le praticien est relu avec la clé service role.
  assert.ok(lectures.some(l => l.url.includes('/rest/v1/praticiens?id=eq.u-baron') && l.auth), 'praticien relu avec la clé service role');

  // Praticien sans adresse : rien envoyé, journalisé, pas d'échec.
  journal.length = 0;
  const rSans = await appel({ type: 'UPDATE', table: 'praticiens', record: praticien({ validation: 'valide', email: null }), old_record: praticien() });
  assert.strictEqual(rSans.statusCode, 200); assert.ok(journal.some(j => j[0] === 'error' && j[1].includes('destinataire absent')));
  lignesResultat.push(`${'compte validé sans adresse e-mail'.padEnd(38)} ${rSans.statusCode}  ${'compte_valide'.padEnd(22)} rien envoyé, journalisé`);

  // Envoi réel vers un serveur SMTP local : en-têtes, puis SMTP injoignable.
  const recus = [];
  const serveur = net.createServer((s) => {
    let donnees = false, tampon = '';
    s.write('220 test ESMTP\r\n');
    s.on('data', (c) => {
      tampon += c.toString('utf8');
      let i;
      while ((i = tampon.indexOf('\r\n')) >= 0) {
        const l = tampon.slice(0, i); tampon = tampon.slice(i + 2);
        if (donnees) { if (l === '.') { donnees = false; s.write('250 OK reçu\r\n'); } else recus[recus.length - 1].push(l); continue; }
        const cmd = l.slice(0, 4).toUpperCase();
        if (cmd === 'EHLO' || cmd === 'HELO') s.write('250-test\r\n250 AUTH PLAIN LOGIN\r\n');
        else if (cmd === 'AUTH') s.write('235 OK\r\n');
        else if (cmd === 'MAIL' || cmd === 'RCPT') s.write('250 OK\r\n');
        else if (cmd === 'DATA') { donnees = true; recus.push([]); s.write('354 go\r\n'); }
        else if (cmd === 'QUIT') { s.write('221 bye\r\n'); s.end(); }
        else s.write('250 OK\r\n');
      }
    });
  });
  await new Promise(ok => serveur.listen(0, '127.0.0.1', ok));
  Object.assign(process.env, { EMAIL_DRY_RUN: 'false', SMTP_HOST: '127.0.0.1', SMTP_PORT: String(serveur.address().port) });
  journal.length = 0;
  const rEnvoi = await appel(CAS[0][1]);
  assert.strictEqual(rEnvoi.statusCode, 200, 'envoi SMTP local');
  const entetes = recus[0].join('\n');
  for (const attendu of ['From: OrthoConnect <contact@orthoconnect.fr>', 'Reply-To: contact@orthoconnect.fr', 'To: baron@example.test', 'Subject:', 'text/html', 'text/plain'])
    assert.ok(entetes.includes(attendu), 'en-tête ' + attendu);
  lignesResultat.push(`${'envoi réel vers un SMTP local'.padEnd(38)} ${rEnvoi.statusCode}  ${'compte_valide'.padEnd(22)} From, Reply-To, To, texte et HTML reçus`);
  serveur.close();

  // SMTP injoignable : 500 sans détail dans la réponse, erreur journalisée sans mot de passe.
  delete require.cache[require.resolve('../netlify/functions/notify.js')];
  const frais = require('../netlify/functions/notify.js');
  Object.assign(process.env, { SMTP_PORT: '1' });
  journal.length = 0;
  const rEchec = await frais.handler({ httpMethod: 'POST', headers: { 'x-webhook-secret': SECRET }, body: JSON.stringify(CAS[1][1]) });
  assert.strictEqual(rEchec.statusCode, 500); assert.strictEqual(rEchec.body, '{"ok":false}');
  assert.ok(journal.some(j => j[1].includes('envoi échoué')) && !journal.some(j => j[1].includes('mot-de-passe-de-test')));
  lignesResultat.push(`${'SMTP injoignable'.padEnd(38)} ${rEchec.statusCode}  ${'compte_refuse'.padEnd(22)} réponse {"ok":false}, erreur journalisée`);

  // Les HTML rendus, pour la capture.
  const sortie = process.argv[2];
  if (sortie) {
    fs.mkdirSync(sortie, { recursive: true });
    const p = praticien({ validation: 'valide' });
    fs.writeFileSync(path.join(sortie, 'valide.html'), _interne.mailCompteValide(p).html);
    fs.writeFileSync(path.join(sortie, 'refuse.html'), _interne.mailCompteRefuse(p).html);
    fs.writeFileSync(path.join(sortie, 'alerte_inscription.html'), _interne.mailAlerte('inscription', p).html);
    fs.writeFileSync(path.join(sortie, 'alerte_fiche.html'), _interne.mailAlerte('revendication', Object.assign({ fiche_id: 'fiche-1' }, p)).html);
    fs.writeFileSync(path.join(sortie, 'alerte_piege.html'), _interne.mailAlerte('inscription', praticien({ nom: piege, ville: '<script>alert(2)</script>', telephone: null })).html);
  }

  console.log = vrai.log;
  console.log(lignesResultat.join('\n'));
  console.log('\nTous les contrôles passent (' + (lignesResultat.length) + ' cas).');
})().catch((e) => { console.log = vrai.log; console.error = vrai.error; console.error('ÉCHEC :', e.message); process.exit(1); });
