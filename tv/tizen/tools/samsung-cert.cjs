// Creates a Samsung TV author + distributor certificate with the same requests as the VS Code Tizen extension, for
// setups where its Certificate Manager fails (e.g. VS Code as Flatpak: its secret-tool dies in the sandbox).
const fs = require('fs'), path = require('path'), http = require('http'), https = require('https');
const { execFile } = require('child_process');
// Usage: node tools/samsung-cert.cjs <TV DUID> <output dir>
// Needs node-forge (`npm install node-forge` or set FORGE to the copy inside the VS Code Tizen extension) and the
// Samsung CA files of the Tizen extension (set SAMSUNG_CA; default: ~/.tizen-extension-platform/...).
// The output dir gets author.p12, distributor.p12 and a random `password` file; keep it out of any repository.
const os = require('os');
const crypto = require('crypto');
const forge = require(process.env.FORGE || 'node-forge');
const CA = (process.env.SAMSUNG_CA
  || path.join(os.homedir(), '.tizen-extension-platform/server/dist/assets/certificate-manager/samsung-tv-ca')) + '/';
const [DUID, outDir] = process.argv.slice(2);
if (!DUID || !outDir) { console.error('Usage: node tools/samsung-cert.cjs <TV DUID> <output dir>'); process.exit(1); }
const OUT = path.resolve(outDir) + '/';
fs.mkdirSync(OUT, { recursive: true, mode: 0o700 });
if (!fs.existsSync(OUT + 'password')) {
  fs.writeFileSync(OUT + 'password', crypto.randomBytes(16).toString('hex'), { mode: 0o600 });
}
const PASSWORD = fs.readFileSync(OUT + 'password', 'utf8').trim();
const PORT = 4794;

function login() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      if (!req.url.includes('/signin/callback')) { res.end('Samsung Authentication Service'); return; }
      let body = '';
      req.on('data', (c) => body += c);
      req.on('end', () => {
        let code = null;
        for (const pair of decodeURIComponent(body).split('&')) {
          const i = pair.indexOf('=');
          if (pair.slice(0, i) === 'code') code = pair.slice(i + 1);
        }
        if (!code) code = new URL('http://localhost' + req.url).searchParams.get('code');
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        if (!code) { res.end('<h2>Login fehlgeschlagen</h2>'); return; }
        res.end('<h2>Login erfolgreich - du kannst das Fenster schliessen.</h2>');
        const j = JSON.parse(decodeURIComponent(code));
        server.close();
        resolve({ accessToken: j.access_token, userId: j.userId });
      });
    });
    server.listen(PORT, () => {
      const url = 'https://account.samsung.com/mobile/account/check.do?serviceID=v285zxnl3h&actionID=StartOAuth2'
        + `&accessToken=Y&redirect_uri=http://localhost:${PORT}/signin/callback`;
      console.log('LOGIN_URL ' + url);
      execFile('xdg-open', [url], () => {});
    });
  });
}

function csr(subject, duids) {
  const keys = forge.pki.rsa.generateKeyPair(2048);
  const req = forge.pki.createCertificationRequest();
  req.publicKey = keys.publicKey;
  req.setSubject(subject);
  if (duids) {
    req.setAttributes([{ name: 'extensionRequest', extensions: [{ name: 'subjectAltName',
      altNames: [{ type: 6, value: 'URN:tizen:packageid=' }, ...duids.map((d) => ({ type: 6, value: 'URN:tizen:deviceid=' + d }))] }] }]);
  }
  req.sign(keys.privateKey, forge.md.sha512.create());
  return { key: keys.privateKey, pem: forge.pki.certificationRequestToPem(req) };
}

function post(url, fields, csrName, csrPem) {
  const b = '----' + Date.now();
  let data = '';
  for (const [k, v] of fields) {
    data += `--${b}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Disposition: form-data; name=${k}\r\n\r\n${v}\r\n`;
  }
  data += `--${b}\r\nContent-Disposition: form-data; name=csr; filename=${csrName}\r\n\r\n${csrPem}\r\n--${b}--\r\n`;
  return new Promise((resolve, reject) => {
    const r = https.request(url, { method: 'POST', headers: { 'Content-Type': `multipart/form-data; boundary=${b}`,
      'Content-Length': Buffer.byteLength(data) } }, (res) => {
      let out = '';
      res.on('data', (c) => out += c);
      res.on('end', () => res.statusCode === 200 ? resolve(out) : reject(new Error(url + ' ' + res.statusCode + ' ' + out)));
    });
    r.on('error', reject);
    r.write(data);
    r.end();
  });
}

function p12(file, key, crtPem, caFile, name) {
  const asn1 = forge.pkcs12.toPkcs12Asn1(key, [forge.pki.certificateFromPem(crtPem),
    forge.pki.certificateFromPem(fs.readFileSync(caFile, 'utf8'))], PASSWORD,
    { algorithm: '3des', count: 2048, saltSize: 8, useMac: true, friendlyName: name, generateLocalKeyId: true });
  fs.writeFileSync(file, Buffer.from(forge.asn1.toDer(asn1).getBytes(), 'binary'), { mode: 0o600 });
}

(async () => {
  const auth = await login();
  console.log('logged in');
  const base = [['access_token', auth.accessToken], ['user_id', auth.userId]];
  const a = csr([{ name: 'commonName', value: 'Resonance' }]);
  const authorCrt = await post('https://svdca.samsungqbe.com/apis/v3/authors', [...base, ['platform', 'VD']], 'author.csr', a.pem);
  fs.writeFileSync(OUT + 'author.crt', authorCrt);
  p12(OUT + 'author.p12', a.key, authorCrt, CA + 'vd_tizen_dev_author_ca.cer', 'resonance');
  console.log('author ok');
  const d = csr([{ name: 'commonName', value: 'TizenSDK' }], [DUID]);
  const distFields = [...base, ['privilege_level', 'Public'], ['developer_type', 'Individual'], ['platform', 'VD']];
  const xml = await post('https://svdca.samsungqbe.com/apis/v1/distributors', distFields, 'distributor.csr', d.pem);
  fs.writeFileSync(OUT + 'device-profile.xml', xml);
  const distCrt = await post('https://svdca.samsungqbe.com/apis/v3/distributors', distFields, 'distributor.csr', d.pem);
  fs.writeFileSync(OUT + 'distributor.crt', distCrt);
  p12(OUT + 'distributor.p12', d.key, distCrt, CA + 'vd_tizen_dev_public2.crt', 'resonance');
  console.log('distributor ok');
})().catch((e) => { console.error('FAILED', e.message); process.exit(1); });
