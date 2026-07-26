package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

type handler struct {
	authorization authorizationEngine
}

func (h handler) handle(request authorizerRequest) authorizerResponse {
	userID, authenticated := extractLocalUserID(request.AuthorizationToken)
	user, userExists := h.authorization.identity(userID)
	allowed, accessGroups := h.authorization.authorize(userID, request.MethodARN)
	if !authenticated || !userExists {
		allowed = false
		userID = "anonymous"
	}

	effect := "Deny"
	if allowed {
		effect = "Allow"
	}
	log.Printf("authorization user=%s effect=%s accessGroups=%s resource=%s",
		userID, effect, strings.Join(accessGroups, ","), request.MethodARN)

	return authorizerResponse{
		PrincipalID: userID,
		PolicyDocument: policyDocument{
			Version: "2012-10-17",
			Statement: []policyStatement{{
				Action: "execute-api:Invoke", Effect: effect, Resource: request.MethodARN,
			}},
		},
		Context: map[string]interface{}{
			"userId":            userID,
			"user":              user.Name,
			"accessRightGroups": strings.Join(accessGroups, ","),
		},
	}
}

// Local-only authentication. The token contains only a user ID; trusted
// attributes and group membership always come from authorization.json.
func extractLocalUserID(value string) (string, bool) {
	const prefix = "Bearer local:"
	if len(value) <= len(prefix) || !strings.EqualFold(value[:len(prefix)], prefix) {
		return "", false
	}
	userID := strings.TrimSpace(value[len(prefix):])
	return userID, userID != ""
}

func main() {
	configPath := os.Getenv("AUTHORIZATION_CONFIG_PATH")
	if configPath == "" {
		configPath = filepath.Join(os.Getenv("LAMBDA_TASK_ROOT"), "authorization.json")
	}
	config, err := loadAuthorizationConfig(configPath)
	if err != nil {
		panic(fmt.Sprintf("initialize authorization engine: %v", err))
	}
	runtimeAPI := os.Getenv("AWS_LAMBDA_RUNTIME_API")
	if runtimeAPI == "" {
		panic("AWS_LAMBDA_RUNTIME_API is not set")
	}
	runRuntime(runtimeAPI, handler{authorization: authorizationEngine{config: config}})
}

// runRuntime implements the AWS Lambda custom runtime HTTP contract using only
// the Go standard library. It works with both provided.al2023 on AWS and Floci.
func runRuntime(runtimeAPI string, h handler) {
	client := &http.Client{}
	baseURL := "http://" + runtimeAPI + "/2018-06-01/runtime/invocation"
	for {
		response, err := client.Get(baseURL + "/next")
		if err != nil {
			log.Fatalf("get next invocation: %v", err)
		}
		requestID := response.Header.Get("Lambda-Runtime-Aws-Request-Id")
		body, readErr := io.ReadAll(response.Body)
		response.Body.Close()
		if readErr != nil {
			postRuntimeError(client, baseURL, requestID, readErr)
			continue
		}
		var request authorizerRequest
		if err := json.Unmarshal(body, &request); err != nil {
			postRuntimeError(client, baseURL, requestID, err)
			continue
		}
		payload, err := json.Marshal(h.handle(request))
		if err != nil {
			postRuntimeError(client, baseURL, requestID, err)
			continue
		}
		postURL := fmt.Sprintf("%s/%s/response", baseURL, requestID)
		postResponse, err := client.Post(postURL, "application/json", bytes.NewReader(payload))
		if err != nil {
			log.Fatalf("post invocation response: %v", err)
		}
		io.Copy(io.Discard, postResponse.Body)
		postResponse.Body.Close()
	}
}

func postRuntimeError(client *http.Client, baseURL, requestID string, invocationErr error) {
	payload, _ := json.Marshal(map[string]string{
		"errorMessage": invocationErr.Error(),
		"errorType":    "AuthorizerInvocationError",
	})
	postURL := fmt.Sprintf("%s/%s/error", baseURL, requestID)
	response, err := client.Post(postURL, "application/json", bytes.NewReader(payload))
	if err != nil {
		log.Fatalf("post invocation error: %v", err)
	}
	io.Copy(io.Discard, response.Body)
	response.Body.Close()
}
