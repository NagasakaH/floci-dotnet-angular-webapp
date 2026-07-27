import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { test } from 'node:test';
import { createHandler } from './index.mjs';

const config = {
  cognitoDomain: 'example.auth.ap-northeast-1.amazoncognito.com',
  clientId: 'client-id',
  callbackUrl: 'https://example.cloudfront.net/auth/callback',
  frontendUrl: 'https://example.cloudfront.net/',
  issuer: 'https://cognito-idp.ap-northeast-1.amazonaws.com/pool-id',
};

function event(uri = '/', querystring = '', cookie = '') {
  return {
    Records: [{
      cf: {
        request: {
          uri,
          querystring,
          method: 'GET',
          headers: cookie ? { cookie: [{ key: 'Cookie', value: cookie }] } : {},
        },
      },
    }],
  };
}

function jwt(privateKey, publicKey, overrides = {}, kid = 'test-key') {
  const now = Math.floor(Date.now() / 1000);
  const header = Buffer.from(JSON.stringify({ alg: 'RS256', kid })).toString('base64url');
  const claims = Buffer.from(JSON.stringify({
    iss: config.issuer,
    aud: config.clientId,
    sub: 'subject-1',
    token_use: 'id',
    iat: now,
    exp: now + 3600,
    ...overrides,
  })).toString('base64url');
  const signature = sign('RSA-SHA256', Buffer.from(`${header}.${claims}`), privateKey).toString('base64url');
  return {
    token: `${header}.${claims}.${signature}`,
    jwk: { ...publicKey.export({ format: 'jwk' }), kid, alg: 'RS256', use: 'sig' },
  };
}

let pairNumber = 0;
function tokenPair(privateKey, publicKey) {
  pairNumber += 1;
  const kid = `test-key-${pairNumber}`;
  const id = jwt(privateKey, publicKey, {}, kid);
  const access = jwt(privateKey, publicKey, {
    aud: undefined,
    client_id: config.clientId,
    token_use: 'access',
    sub: 'subject-1',
    username: 'demo@example.com',
    'cognito:groups': ['hello-readers'],
  }, kid);
  return { id, access };
}

test('redirects an unauthenticated request to Cognito with PKCE', async () => {
  const result = await createHandler(config)(event());
  assert.equal(result.status, '302');
  const location = new URL(result.headers.location[0].value);
  assert.equal(location.pathname, '/oauth2/authorize');
  assert.equal(location.searchParams.get('code_challenge_method'), 'S256');
  assert.equal(result.headers['set-cookie'].length, 3);
});

test('passes a request with a valid signed ID token', async () => {
  const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const { id, access } = tokenPair(privateKey, publicKey);
  const fetchFn = async () => new Response(JSON.stringify({ keys: [id.jwk] }), { status: 200 });
  const request = event('/', '', `floci_session=${id.token}; floci_access=${access.token}`);
  const result = await createHandler(config, fetchFn)(request);
  assert.equal(result, request.Records[0].cf.request);
});

test('returns the access token only through the authenticated same-origin endpoint', async () => {
  const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const { id, access } = tokenPair(privateKey, publicKey);
  const fetchFn = async () => new Response(JSON.stringify({ keys: [id.jwk] }), { status: 200 });
  const result = await createHandler(config, fetchFn)(
    event('/auth/token', '', `floci_session=${id.token}; floci_access=${access.token}`),
  );
  assert.equal(result.status, '200');
  assert.equal(JSON.parse(result.body).accessToken, access.token);
  assert.deepEqual(JSON.parse(result.body).groups, ['hello-readers']);
  assert.equal(result.headers['cache-control'][0].value, 'no-cache, no-store, must-revalidate');
});

test('clears both tokens and redirects through Cognito logout', async () => {
  const result = await createHandler(config)(event('/auth/logout', '', 'floci_session=value'));
  assert.equal(result.status, '302');
  assert.equal(new URL(result.headers.location[0].value).pathname, '/logout');
  assert.equal(result.headers['set-cookie'].length, 2);
  assert.match(result.headers['set-cookie'][0].value, /Max-Age=0/);
});
