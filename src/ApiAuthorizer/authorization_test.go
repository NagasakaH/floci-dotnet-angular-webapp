package main

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"
)

const helloARN = "arn:aws:execute-api:ap-northeast-1:000000000000:id/dev/GET/api/hello"
const searchARN = "arn:aws:execute-api:ap-northeast-1:000000000000:id/dev/POST/api/search-jobs"
const fileARN = "arn:aws:execute-api:ap-northeast-1:000000000000:id/dev/POST/api/file-jobs"

func testEngine(t *testing.T) authorizationEngine {
	t.Helper()
	config, err := loadAuthorizationConfig("authorization.json")
	if err != nil {
		t.Fatal(err)
	}
	return authorizationEngine{config: config}
}

func TestUserGroupGrantsAccess(t *testing.T) {
	allowed, groups := testEngine(t).authorize("user-001", helloARN)
	if !allowed || !contains(groups, "hello-readers") {
		t.Fatalf("allowed=%v groups=%v", allowed, groups)
	}
}

func TestIndividualUserGrant(t *testing.T) {
	allowed, groups := testEngine(t).authorize("user-003", helloARN)
	if !allowed || !contains(groups, "hello-readers") {
		t.Fatalf("allowed=%v groups=%v", allowed, groups)
	}
}

func TestUserWithoutMatchingAccessGroupIsDenied(t *testing.T) {
	allowed, _ := testEngine(t).authorize("user-002", helloARN)
	if allowed {
		t.Fatal("user-002 must not access hello")
	}
}

func TestActionAndResourceMustBothMatch(t *testing.T) {
	engine := testEngine(t)
	for _, arn := range []string{
		"arn:aws:execute-api:region:account:id/dev/POST/api/hello",
		"arn:aws:execute-api:region:account:id/dev/GET/api/admin",
	} {
		if allowed, _ := engine.authorize("user-001", arn); allowed {
			t.Fatalf("unexpected allow for %s", arn)
		}
	}
}

func TestLocalTokenContainsOnlyUserID(t *testing.T) {
	userID, ok := extractLocalUserID("Bearer local:user-001")
	if !ok || userID != "user-001" {
		t.Fatalf("userID=%q ok=%v", userID, ok)
	}
}

func TestIdentityProviderGroupGrant(t *testing.T) {
	identity := authenticatedIdentity{
		UserID: "cognito-sub", Name: "demo@example.com",
		IdentityProviderGroups: []string{"hello-readers"},
	}
	allowed, groups := testEngine(t).authorizeIdentity(identity, helloARN)
	if !allowed || !contains(groups, "hello-readers") {
		t.Fatalf("allowed=%v groups=%v", allowed, groups)
	}
}

func TestSearchJobPermissions(t *testing.T) {
	engine := testEngine(t)
	for _, arn := range []string{
		searchARN,
		"arn:aws:execute-api:ap-northeast-1:000000000000:id/dev/GET/api/search-jobs/job-1",
	} {
		if allowed, groups := engine.authorize("user-001", arn); !allowed || !contains(groups, "search-job-users") {
			t.Fatalf("arn=%s allowed=%v groups=%v", arn, allowed, groups)
		}
	}
	if allowed, _ := engine.authorize(
		"user-002",
		"arn:aws:execute-api:ap-northeast-1:000000000000:id/dev/POST/api/search-jobs",
	); allowed {
		t.Fatal("user-002 must not create search jobs")
	}
}

func TestFileIngestPermissions(t *testing.T) {
	engine := testEngine(t)
	for _, arn := range []string{
		fileARN,
		"arn:aws:execute-api:ap-northeast-1:000000000000:id/dev/GET/api/file-jobs/job-1",
	} {
		if allowed, groups := engine.authorize("user-001", arn); !allowed || !contains(groups, "file-ingest-users") {
			t.Fatalf("arn=%s allowed=%v groups=%v", arn, allowed, groups)
		}
	}
	if allowed, _ := engine.authorize("user-002", fileARN); allowed {
		t.Fatal("user-002 must not create file ingest jobs")
	}
}

func TestCognitoAccessTokenAuthentication(t *testing.T) {
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	kid := "test-key"
	now := time.Now().Unix()
	claims := map[string]any{
		"sub": "cognito-sub", "iss": "https://issuer.example", "client_id": "client-id",
		"token_use": "access", "username": "demo@example.com",
		"cognito:groups": []string{"hello-readers"}, "iat": now, "exp": now + 300,
	}
	token := signTestJWT(t, privateKey, kid, claims)
	authenticator := tokenAuthenticator{
		issuer: "https://issuer.example", clientID: "client-id",
		mu: &sync.Mutex{}, keys: map[string]*rsa.PublicKey{kid: &privateKey.PublicKey},
	}
	identity, err := authenticator.authenticate("Bearer "+token, testEngine(t))
	if err != nil {
		t.Fatal(err)
	}
	if identity.UserID != "cognito-sub" || !contains(identity.IdentityProviderGroups, "hello-readers") {
		t.Fatalf("unexpected identity: %#v", identity)
	}
	if allowed, _ := testEngine(t).authorizeIdentity(identity, helloARN); !allowed {
		t.Fatal("Cognito hello-readers member must be allowed")
	}

	tampered := strings.Split(token, ".")
	tampered[1] = base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"attacker"}`))
	if _, err := authenticator.authenticate("Bearer "+strings.Join(tampered, "."), testEngine(t)); err == nil {
		t.Fatal("tampered token must be rejected")
	}
}

func signTestJWT(t *testing.T, privateKey *rsa.PrivateKey, kid string, claims map[string]any) string {
	t.Helper()
	header, _ := json.Marshal(map[string]string{"alg": "RS256", "kid": kid})
	payload, _ := json.Marshal(claims)
	signingInput := base64.RawURLEncoding.EncodeToString(header) + "." +
		base64.RawURLEncoding.EncodeToString(payload)
	digest := sha256.Sum256([]byte(signingInput))
	signature, err := rsa.SignPKCS1v15(rand.Reader, privateKey, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(signature)
}
