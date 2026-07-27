package main

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

type tokenAuthenticator struct {
	allowLocalTokens bool
	issuer           string
	clientID         string
	jwksURL          string
	client           *http.Client
	mu               *sync.Mutex
	keys             map[string]*rsa.PublicKey
}

type jwtClaims struct {
	Subject         string   `json:"sub"`
	Issuer          string   `json:"iss"`
	ClientID        string   `json:"client_id"`
	TokenUse        string   `json:"token_use"`
	Username        string   `json:"username"`
	CognitoUsername string   `json:"cognito:username"`
	Groups          []string `json:"cognito:groups"`
	ExpiresAt       int64    `json:"exp"`
	IssuedAt        int64    `json:"iat"`
}

type jwksDocument struct {
	Keys []jsonWebKey `json:"keys"`
}

type jsonWebKey struct {
	KeyID     string `json:"kid"`
	KeyType   string `json:"kty"`
	Algorithm string `json:"alg"`
	Use       string `json:"use"`
	Modulus   string `json:"n"`
	Exponent  string `json:"e"`
}

func newTokenAuthenticatorFromEnvironment() (tokenAuthenticator, error) {
	authMode := strings.TrimSpace(os.Getenv("AUTH_MODE"))
	issuer := strings.TrimSuffix(os.Getenv("COGNITO_ISSUER"), "/")
	clientID := os.Getenv("COGNITO_CLIENT_ID")
	switch authMode {
	case "local":
		if issuer != "" || clientID != "" {
			return tokenAuthenticator{}, errors.New("local AUTH_MODE must not configure Cognito")
		}
	case "cognito":
		if issuer == "" || clientID == "" {
			return tokenAuthenticator{}, errors.New("cognito AUTH_MODE requires COGNITO_ISSUER and COGNITO_CLIENT_ID")
		}
	default:
		return tokenAuthenticator{}, errors.New("AUTH_MODE must be local or cognito")
	}
	return tokenAuthenticator{
		allowLocalTokens: authMode == "local",
		issuer:           issuer,
		clientID:         clientID,
		jwksURL:          issuer + "/.well-known/jwks.json",
		client:           &http.Client{Timeout: 3 * time.Second},
		mu:               &sync.Mutex{},
		keys:             map[string]*rsa.PublicKey{},
	}, nil
}

func (a tokenAuthenticator) authenticate(value string, engine authorizationEngine) (authenticatedIdentity, error) {
	if userID, ok := extractLocalUserID(value); ok && a.allowLocalTokens {
		user, exists := engine.identity(userID)
		if !exists {
			return authenticatedIdentity{}, errors.New("unknown local user")
		}
		return authenticatedIdentity{UserID: userID, Name: user.Name, Attributes: user.Attributes}, nil
	}
	const prefix = "Bearer "
	if !strings.HasPrefix(value, prefix) || a.issuer == "" {
		return authenticatedIdentity{}, errors.New("unsupported token")
	}
	claims, err := a.verifyAccessToken(strings.TrimSpace(strings.TrimPrefix(value, prefix)))
	if err != nil {
		return authenticatedIdentity{}, err
	}
	name := claims.Username
	if name == "" {
		name = claims.CognitoUsername
	}
	if name == "" {
		name = claims.Subject
	}
	return authenticatedIdentity{
		UserID: claims.Subject, Name: name,
		Attributes:             map[string]string{"username": name},
		IdentityProviderGroups: claims.Groups,
	}, nil
}

func (a tokenAuthenticator) verifyAccessToken(token string) (jwtClaims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return jwtClaims{}, errors.New("JWT must have three parts")
	}
	var header struct {
		Algorithm string `json:"alg"`
		KeyID     string `json:"kid"`
	}
	if err := decodeJWTJSON(parts[0], &header); err != nil || header.Algorithm != "RS256" || header.KeyID == "" {
		return jwtClaims{}, errors.New("invalid JWT header")
	}
	var claims jwtClaims
	if err := decodeJWTJSON(parts[1], &claims); err != nil {
		return jwtClaims{}, errors.New("invalid JWT claims")
	}
	now := time.Now().Unix()
	if claims.Issuer != a.issuer || claims.ClientID != a.clientID || claims.TokenUse != "access" ||
		claims.Subject == "" || claims.ExpiresAt <= now || claims.IssuedAt <= 0 || claims.IssuedAt > now+60 {
		return jwtClaims{}, errors.New("invalid access token claims")
	}
	key, err := a.signingKey(header.KeyID)
	if err != nil {
		return jwtClaims{}, err
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return jwtClaims{}, errors.New("invalid JWT signature encoding")
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], signature); err != nil {
		return jwtClaims{}, errors.New("invalid JWT signature")
	}
	return claims, nil
}

func decodeJWTJSON(value string, target any) error {
	content, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		return err
	}
	return json.Unmarshal(content, target)
}

func (a tokenAuthenticator) signingKey(kid string) (*rsa.PublicKey, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if key := a.keys[kid]; key != nil {
		return key, nil
	}
	request, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, a.jwksURL, nil)
	response, err := a.client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("get JWKS: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("get JWKS: HTTP %d", response.StatusCode)
	}
	var document jwksDocument
	if err := json.NewDecoder(response.Body).Decode(&document); err != nil {
		return nil, fmt.Errorf("decode JWKS: %w", err)
	}
	for _, jwk := range document.Keys {
		if jwk.KeyType != "RSA" || jwk.Algorithm != "RS256" {
			continue
		}
		modulus, nErr := base64.RawURLEncoding.DecodeString(jwk.Modulus)
		exponent, eErr := base64.RawURLEncoding.DecodeString(jwk.Exponent)
		if nErr != nil || eErr != nil || len(exponent) == 0 {
			continue
		}
		e := 0
		for _, b := range exponent {
			e = e<<8 + int(b)
		}
		a.keys[jwk.KeyID] = &rsa.PublicKey{N: new(big.Int).SetBytes(modulus), E: e}
	}
	if key := a.keys[kid]; key != nil {
		return key, nil
	}
	return nil, errors.New("JWT signing key not found")
}
