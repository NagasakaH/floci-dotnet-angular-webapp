package main

import "testing"

const helloARN = "arn:aws:execute-api:ap-northeast-1:000000000000:id/dev/GET/api/hello"

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
