import { createHash, createPublicKey, randomBytes, verify } from 'node:crypto';
import { readFileSync } from 'node:fs';

const SESSION_COOKIE = 'floci_session';
const ACCESS_COOKIE = 'floci_access';
const STATE_COOKIE = 'floci_oauth_state';
const VERIFIER_COOKIE = 'floci_pkce_verifier';
const NONCE_COOKIE = 'floci_oidc_nonce';
const TRANSIENT_MAX_AGE = 300;
let cachedJwks;

function base64Url(bytes) {
  return Buffer.from(bytes).toString('base64url');
}

function parseCookies(headers) {
  const value = headers.cookie?.map((item) => item.value).join('; ') ?? '';
  return Object.fromEntries(
    value
      .split(';')
      .map((part) => part.trim())
      .filter(Boolean)
      .map((part) => {
        const separator = part.indexOf('=');
        return separator < 0
          ? [part, '']
          : [part.slice(0, separator), decodeURIComponent(part.slice(separator + 1))];
      }),
  );
}

function cookie(name, value, options = '') {
  return `${name}=${encodeURIComponent(value)}; Path=/; Secure; HttpOnly; SameSite=Lax${options}`;
}

function clearCookie(name) {
  return cookie(name, '', '; Max-Age=0');
}

function response(status, statusDescription, headers = {}, body = '') {
  return {
    status: String(status),
    statusDescription,
    headers: Object.fromEntries(
      Object.entries(headers).map(([name, values]) => [
        name.toLowerCase(),
        (Array.isArray(values) ? values : [values]).map((value) => ({
          key: name,
          value,
        })),
      ]),
    ),
    body,
  };
}

function redirect(location, cookies = []) {
  const headers = {
    Location: location,
    'Cache-Control': 'no-cache, no-store, must-revalidate',
  };
  if (cookies.length > 0) {
    headers['Set-Cookie'] = cookies;
  }
  return response(302, 'Found', headers);
}

function errorResponse(message) {
  const escaped = message.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  return response(
    401,
    'Unauthorized',
    {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-cache, no-store, must-revalidate',
    },
    `<!doctype html><html lang="ja"><meta charset="utf-8"><title>Authentication error</title><body><h1>ログインできませんでした</h1><p>${escaped}</p><p><a href="/">ログインをやり直す</a></p></body></html>`,
  );
}

function decodeJwtPart(value) {
  return JSON.parse(Buffer.from(value, 'base64url').toString('utf8'));
}

async function getJwks(config, fetchFn) {
  if (cachedJwks) {
    return cachedJwks;
  }
  const jwksUrl = `${config.issuer}/.well-known/jwks.json`;
  const jwksResponse = await fetchFn(jwksUrl);
  if (!jwksResponse.ok) {
    throw new Error(`JWKS endpoint returned ${jwksResponse.status}`);
  }
  cachedJwks = await jwksResponse.json();
  return cachedJwks;
}

async function verifyToken(token, config, fetchFn, tokenUse, expectedNonce) {
  const parts = token.split('.');
  if (parts.length !== 3) {
    throw new Error(`${tokenUse} token format is invalid`);
  }

  const header = decodeJwtPart(parts[0]);
  const claims = decodeJwtPart(parts[1]);
  if (header.alg !== 'RS256' || !header.kid) {
    throw new Error(`${tokenUse} token algorithm is invalid`);
  }

  let jwks = await getJwks(config, fetchFn);
  let jwk = jwks.keys.find((key) => key.kid === header.kid);
  if (!jwk) {
    cachedJwks = undefined;
    jwks = await getJwks(config, fetchFn);
    jwk = jwks.keys.find((key) => key.kid === header.kid);
  }
  if (!jwk) {
    throw new Error(`${tokenUse} token signing key was not found`);
  }

  const validSignature = verify(
    'RSA-SHA256',
    Buffer.from(`${parts[0]}.${parts[1]}`),
    createPublicKey({ key: jwk, format: 'jwk' }),
    Buffer.from(parts[2], 'base64url'),
  );
  if (!validSignature) {
    throw new Error(`${tokenUse} token signature is invalid`);
  }

  const now = Math.floor(Date.now() / 1000);
  if (
    claims.iss !== config.issuer ||
    (tokenUse === 'id' ? claims.aud : claims.client_id) !== config.clientId ||
    claims.token_use !== tokenUse ||
    typeof claims.iat !== 'number' ||
    claims.iat <= 0 ||
    claims.iat > now + 60 ||
    typeof claims.exp !== 'number' ||
    claims.exp <= now
  ) {
    throw new Error(`${tokenUse} token claims are invalid`);
  }
  if (expectedNonce && claims.nonce !== expectedNonce) {
    throw new Error('ID token nonce is invalid');
  }
  return claims;
}

function verifyIdToken(token, config, fetchFn, expectedNonce) {
  return verifyToken(token, config, fetchFn, 'id', expectedNonce);
}

function verifyAccessToken(token, config, fetchFn) {
  return verifyToken(token, config, fetchFn, 'access');
}

function beginLogin(config, clearSession = false) {
  const state = base64Url(randomBytes(24));
  const verifier = base64Url(randomBytes(48));
  const nonce = base64Url(randomBytes(24));
  const challenge = base64Url(createHash('sha256').update(verifier).digest());
  const authorizeUrl = new URL(`https://${config.cognitoDomain}/oauth2/authorize`);
  authorizeUrl.search = new URLSearchParams({
    response_type: 'code',
    client_id: config.clientId,
    redirect_uri: config.callbackUrl,
    scope: 'openid email profile',
    state,
    nonce,
    code_challenge: challenge,
    code_challenge_method: 'S256',
  }).toString();

  const cookies = [
    cookie(STATE_COOKIE, state, `; Max-Age=${TRANSIENT_MAX_AGE}`),
    cookie(VERIFIER_COOKIE, verifier, `; Max-Age=${TRANSIENT_MAX_AGE}`),
    cookie(NONCE_COOKIE, nonce, `; Max-Age=${TRANSIENT_MAX_AGE}`),
  ];
  if (clearSession) {
    cookies.push(clearCookie(SESSION_COOKIE));
    cookies.push(clearCookie(ACCESS_COOKIE));
  }
  return redirect(authorizeUrl.toString(), cookies);
}

async function completeLogin(request, config, fetchFn) {
  const parameters = new URLSearchParams(request.querystring);
  const cookies = parseCookies(request.headers);
  if (parameters.get('error')) {
    return errorResponse(parameters.get('error_description') ?? parameters.get('error'));
  }
  if (
    !parameters.get('code') ||
    !parameters.get('state') ||
    parameters.get('state') !== cookies[STATE_COOKIE] ||
    !cookies[VERIFIER_COOKIE] ||
    !cookies[NONCE_COOKIE]
  ) {
    return errorResponse('OAuth callbackの検証に失敗しました。');
  }

  const tokenResponse = await fetchFn(`https://${config.cognitoDomain}/oauth2/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      client_id: config.clientId,
      code: parameters.get('code'),
      redirect_uri: config.callbackUrl,
      code_verifier: cookies[VERIFIER_COOKIE],
    }).toString(),
  });
  if (!tokenResponse.ok) {
    return errorResponse(`Token endpoint returned ${tokenResponse.status}`);
  }

  const tokens = await tokenResponse.json();
  if (!tokens.id_token || !tokens.access_token) {
    return errorResponse('必要なトークンが返されませんでした。');
  }
  const claims = await verifyIdToken(
    tokens.id_token,
    config,
    fetchFn,
    cookies[NONCE_COOKIE],
  );
  const accessClaims = await verifyAccessToken(tokens.access_token, config, fetchFn);
  if (accessClaims.sub !== claims.sub) {
    return errorResponse('ID tokenとaccess tokenのユーザーが一致しません。');
  }
  const now = Math.floor(Date.now() / 1000);
  const sessionMaxAge = Math.max(1, Math.min(3600, claims.exp - now));
  const accessMaxAge = Math.max(1, Math.min(3600, accessClaims.exp - now));

  return redirect(config.frontendUrl, [
    cookie(SESSION_COOKIE, tokens.id_token, `; Max-Age=${sessionMaxAge}`),
    cookie(ACCESS_COOKIE, tokens.access_token, `; Max-Age=${accessMaxAge}`),
    clearCookie(STATE_COOKIE),
    clearCookie(VERIFIER_COOKIE),
    clearCookie(NONCE_COOKIE),
  ]);
}

export function createHandler(config, fetchFn = fetch) {
  return async (event) => {
    const request = event.Records[0].cf.request;
    const cookies = parseCookies(request.headers);

    if (request.uri === '/auth/logout') {
      const logoutUrl = new URL(`https://${config.cognitoDomain}/logout`);
      logoutUrl.search = new URLSearchParams({
        client_id: config.clientId,
        logout_uri: config.frontendUrl,
      }).toString();
      return redirect(logoutUrl.toString(), [
        clearCookie(SESSION_COOKIE),
        clearCookie(ACCESS_COOKIE),
      ]);
    }

    if (request.uri === '/auth/callback') {
      return completeLogin(request, config, fetchFn);
    }

    if (!cookies[SESSION_COOKIE] || !cookies[ACCESS_COOKIE]) {
      return beginLogin(config);
    }

    try {
      const idClaims = await verifyIdToken(cookies[SESSION_COOKIE], config, fetchFn);
      const accessClaims = await verifyAccessToken(cookies[ACCESS_COOKIE], config, fetchFn);
      if (idClaims.sub !== accessClaims.sub) {
        throw new Error('Session token subjects do not match');
      }
      if (request.uri === '/auth/token') {
        return response(
          200,
          'OK',
          {
            'Content-Type': 'application/json; charset=utf-8',
            'Cache-Control': 'no-cache, no-store, must-revalidate',
          },
          JSON.stringify({
            accessToken: cookies[ACCESS_COOKIE],
            expiresAt: accessClaims.exp,
            username: idClaims.email ?? accessClaims.username ?? accessClaims['cognito:username'] ?? idClaims.sub,
            groups: accessClaims['cognito:groups'] ?? [],
          }),
        );
      }
      return request;
    } catch (error) {
      console.warn('Session validation failed', error.message);
      return beginLogin(config, true);
    }
  };
}

function loadConfig() {
  return JSON.parse(readFileSync(new URL('./config.json', import.meta.url), 'utf8'));
}

export const handler = async (event) => createHandler(loadConfig())(event);
